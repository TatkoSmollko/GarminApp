// RRBuffer.mc
// Rolling circular buffer for RR intervals with Kubios-style artifact correction.
//
// ============================================================================
// ARTIFACT HANDLING STRATEGY (Phase 2 upgrade)
// ============================================================================
//
// Phase 1 simply rejected beats that failed the relative-change threshold,
// which leaves gaps in the time series and can distort DFA α1.
//
// Phase 2 uses linear interpolation correction, matching the Kubios standard
// pipeline (Tarvainen et al. 2014, Comput Methods Programs Biomed):
//
//   When an incoming RR interval is flagged as a suspected artifact:
//     1. Hold it in a one-slot "pending" buffer instead of rejecting outright.
//     2. On the next incoming sample:
//        a) If the next sample is clean (close to the last accepted value),
//           interpolate: corrected = (lastAccepted + nextClean) / 2.
//           Write the interpolated value, then accept the clean sample normally.
//        b) If the next sample is also suspicious, discard the pending sample
//           and treat this as a run of artifacts (keep lastAccepted as anchor).
//
//   Absolute-range violations (< 300 ms or > 2000 ms) are hardware errors;
//   they are rejected outright with no interpolation attempt.
//
// Quality score separates "interpolated" (corrected, usable) beats from
// "rejected" (dropped, unusable) ones so DFA confidence reflects reality.
//
// Reference: Kubios HRV Standard 3.x — artifact correction documentation.

import Toybox.Lang;
import Toybox.Math;

class RRBuffer {

    // ---- Configuration ----

    private const BUFFER_SIZE = 256;   // ~4 min at 60 bpm

    // Absolute physiological limits (ms).
    private const RR_MIN_MS = 300;     // > 200 bpm
    private const RR_MAX_MS = 2000;    // < 30 bpm

    // Relative change threshold for ectopic/artifact detection.
    // 20% matches the Kubios default. Reference: Tarvainen et al. 2014.
    private const MAX_RELATIVE_CHANGE = 0.20f;

    // ---- Buffer ----

    private var buffer as Array;   // Float[BUFFER_SIZE], circular
    private var head   as Number;  // next write index
    private var count  as Number;  // valid samples currently held

    // ---- Artifact correction state ----

    private var lastAcceptedRR    as Float;  // last value written to buffer
    private var pendingArtifactRR as Float;  // suspect value held for lookahead (-1 = none)

    // ---- Quality accounting ----

    private var totalOffered      as Number;  // all intervals offered
    private var totalRejected     as Number;  // absolute-range or cluster rejections
    private var totalInterpolated as Number;  // corrected by interpolation

    function initialize() {
        buffer = new [BUFFER_SIZE];
        for (var i = 0; i < BUFFER_SIZE; i++) { buffer[i] = 0.0f; }

        head              = 0;
        count             = 0;
        lastAcceptedRR    = -1.0f;
        pendingArtifactRR = -1.0f;
        totalOffered      = 0;
        totalRejected     = 0;
        totalInterpolated = 0;
    }

    // -------------------------------------------------------------------------
    // addInterval(rrMs)
    //
    // Adds one RR interval (ms) through the artifact correction pipeline.
    // Returns true if the sample ultimately contributes to the buffer
    // (either accepted directly or through an interpolation that resolved
    // a previously pending artifact).
    // -------------------------------------------------------------------------
    function addInterval(rrMs as Number) as Boolean {
        totalOffered++;
        var rr = rrMs.toFloat();

        // ---- Absolute range check — hardware error, reject immediately ----
        if (rr < RR_MIN_MS || rr > RR_MAX_MS) {
            totalRejected++;
            // Do not touch lastAcceptedRR — keep the last good value as anchor.
            // If there is a pending artifact, discard it too.
            if (pendingArtifactRR >= 0.0f) {
                totalRejected++;
                pendingArtifactRR = -1.0f;
            }
            return false;
        }

        // ---- No prior reference — accept as first sample ----
        if (lastAcceptedRR < 0.0f) {
            _writeToBuffer(rr);
            lastAcceptedRR = rr;
            return true;
        }

        // ---- Relative change check ----
        var relChange = (rr - lastAcceptedRR).abs() / lastAcceptedRR;
        var isClean   = relChange <= MAX_RELATIVE_CHANGE;

        if (isClean) {
            // ---- This sample is clean ----

            if (pendingArtifactRR >= 0.0f) {
                // Resolve the pending artifact via interpolation.
                // The corrected beat = midpoint between last accepted and this clean value.
                // This preserves the RR trend without injecting a large jump.
                var interpolated = (lastAcceptedRR + rr) / 2.0f;
                _writeToBuffer(interpolated);
                totalInterpolated++;
                pendingArtifactRR = -1.0f;
            }

            _writeToBuffer(rr);
            lastAcceptedRR = rr;
            return true;

        } else {
            // ---- This sample looks like an artifact ----

            if (pendingArtifactRR >= 0.0f) {
                // Two consecutive artifacts — the interpolation strategy fails here.
                // Discard the pending artifact; treat this sample as a new pending.
                // The anchor (lastAcceptedRR) is deliberately NOT updated so that
                // the next clean beat can recover against the original reference.
                totalRejected++;
                pendingArtifactRR = rr;  // replace pending with the newer suspect
            } else {
                // First artifact — hold for lookahead resolution.
                pendingArtifactRR = rr;
                // Not counted as rejected yet; it may be interpolated next tick.
            }
            return false;
        }
    }

    // -------------------------------------------------------------------------
    // copyWindow(dest, windowSize)
    //
    // Copies the most recent `windowSize` samples (chronological order) into
    // the pre-allocated `dest` array. Returns the actual number of samples
    // copied (may be < windowSize if buffer not yet full).
    // -------------------------------------------------------------------------
    function copyWindow(dest as Array, windowSize as Number) as Number {
        var available = count < windowSize ? count : windowSize;
        if (available == 0) { return 0; }

        var start = (head - available + BUFFER_SIZE) % BUFFER_SIZE;
        for (var i = 0; i < available; i++) {
            dest[i] = buffer[(start + i) % BUFFER_SIZE];
        }
        return available;
    }

    // -------------------------------------------------------------------------
    // qualityScore() → 0.0–1.0
    //
    // Combines three factors:
    //   1. Hard rejection rate (absolute-range / multi-artifact clusters)
    //   2. Interpolation rate (penalised less than rejection — beat is corrected)
    //   3. Buffer readiness (ramps 0→1 as buffer fills)
    //
    // Interpolated beats are penalised at half the weight of rejected ones.
    // -------------------------------------------------------------------------
    function qualityScore() as Float {
        if (totalOffered == 0) { return 0.0f; }

        var n = totalOffered.toFloat();
        // Each rejected beat costs a full penalty unit; each interpolated beat
        // costs half (it was corrected, not dropped, so DFA sees a value).
        var penaltyUnits = totalRejected.toFloat() + totalInterpolated.toFloat() * 0.5f;
        var acceptanceScore = 1.0f - (penaltyUnits / n);
        if (acceptanceScore < 0.0f) { acceptanceScore = 0.0f; }

        // Readiness: scale from 0 → 1 as buffer fills towards BUFFER_SIZE.
        var readiness = count.toFloat() / BUFFER_SIZE.toFloat();
        if (readiness > 1.0f) { readiness = 1.0f; }

        return acceptanceScore * readiness;
    }

    // True when sufficient samples are in the buffer for a reliable DFA estimate.
    function isReadyForDFA() as Boolean {
        return count >= 128;
    }

    function samplesAvailable() as Number {
        return count;
    }

    // Number of beats that were interpolated (corrected from artifact).
    function interpolatedCount() as Number {
        return totalInterpolated;
    }

    // Number of beats that were fully rejected (hardware error or artifact cluster).
    function rejectedCount() as Number {
        return totalRejected;
    }

    // Reset — called at the start of a new test.
    function reset() {
        head              = 0;
        count             = 0;
        lastAcceptedRR    = -1.0f;
        pendingArtifactRR = -1.0f;
        totalOffered      = 0;
        totalRejected     = 0;
        totalInterpolated = 0;
        for (var i = 0; i < BUFFER_SIZE; i++) { buffer[i] = 0.0f; }
    }

    // ---- Private ----

    private function _writeToBuffer(rr as Float) as Void {
        buffer[head] = rr;
        head = (head + 1) % BUFFER_SIZE;
        if (count < BUFFER_SIZE) { count++; }
    }
}
