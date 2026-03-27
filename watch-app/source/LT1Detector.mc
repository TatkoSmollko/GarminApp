// LT1Detector.mc
// Robust LT1 (aerobic threshold) estimation from DFA alpha1.
//
// ============================================================================
// DETECTION STRATEGY
// ============================================================================
//
// Physiology: LT1 corresponds to DFA alpha1 ≈ 0.75.  As exercise intensity
// increases, alpha1 declines from ~1.0 (rest) toward ~0.5 (heavy intensity).
// The transition through 0.75 marks the shift from a fully aerobic to a
// mixed metabolic regime.
//
// Problem: alpha1 is noisy on a per-window basis.  A naive "first crossing"
// approach would be unreliable.  We instead:
//
//   1. Accumulate per-stage mean DFA alpha1 (averaged over valid windows
//      in the last 2 minutes of each 4-minute stage — the "settling window").
//   2. After each stage completes, check if the stage-mean series has
//      crossed or bracketed 0.75.
//   3. Use linear interpolation between the last stage above 0.75 and the
//      first stage below 0.75 to estimate the exact intensity at the crossing.
//   4. Compute a confidence score based on:
//      - RR signal quality throughout the test
//      - Number of valid DFA windows contributing to each stage mean
//      - Slope of the alpha1 decline (steep = cleaner crossing estimate)
//      - Whether the crossing was observed within the expected intensity range
//        (stages 3–6; if LT1 is in stage 1–2 the test was too easy)
//
// Fallback: If alpha1 never crosses 0.75 during the test, we report "not
// detected" with confidence 0.  If it crosses before stage 3, we flag the
// result as low confidence (test likely not intense enough for the athlete).
//
// ============================================================================
// LT1 INTERPOLATION
// ============================================================================
//
// Let stage A be the last stage where mean_alpha1 > 0.75,
// and stage B be the first stage where mean_alpha1 <= 0.75.
// Let HR_A, HR_B and DFA_A, DFA_B be the respective means.
//
// Linear interpolation:
//   t = (0.75 - DFA_A) / (DFA_B - DFA_A)     [0 ≤ t ≤ 1]
//   LT1_HR = HR_A + t * (HR_B - HR_A)
//
// The same formula applies for pace and power.

import Toybox.Lang;
import Toybox.Math;

class LT1Detector {

    // The DFA alpha1 threshold defining LT1.
    // References: Gronwald et al. 2020, Altini & Plews 2021.
    private const LT1_THRESHOLD = 0.75f;

    // We only consider stages 1–6 (index 0–5).  LT1 detection in stage 1 or 2
    // suggests the test was too easy for the athlete; flag as low confidence.
    private const MIN_VALID_DETECTION_STAGE = 3;  // 1-based, stage 3 or later

    // Minimum number of DFA windows a stage must have to be considered valid.
    // Each window is ~30 s, so 2 min of valid data ≈ 4 windows minimum.
    private const MIN_WINDOWS_FOR_VALID_STAGE = 3;

    // ---- Accumulated per-stage data ----
    // These are updated from TestOrchestrator after each stage finishes.

    private var stageMeanDfa  as Array or Null;  // Float[6], -1.0 = not computed
    private var stageMeanHr   as Array or Null;  // Float[6]
    private var stageMeanPace as Array or Null;  // Float[6]
    private var stageMeanPower as Array or Null; // Float[6]
    private var stageValidity  as Array or Null; // Float[6]: fraction of valid windows
    private var stageWindows   as Array or Null; // Number[6]: DFA window count
    private var stageRrQuality as Array or Null; // Float[6]: mean RR quality

    private var stagesCompleted as Number or Null;

    // ---- Last computed result ----
    private var lastResult as Dictionary or Null;

    function initialize() {
        _reset();
    }

    function reset() as Void {
        _reset();
    }

    private function _reset() as Void {
        stageMeanDfa   = new [6];
        stageMeanHr    = new [6];
        stageMeanPace  = new [6];
        stageMeanPower = new [6];
        stageValidity  = new [6];
        stageWindows   = new [6];
        stageRrQuality = new [6];
        stagesCompleted = 0;
        lastResult = null;

        for (var i = 0; i < 6; i++) {
            stageMeanDfa[i]   = -1.0f;
            stageMeanHr[i]    = 0.0f;
            stageMeanPace[i]  = 0.0f;
            stageMeanPower[i] = 0.0f;
            stageValidity[i]  = 0.0f;
            stageWindows[i]   = 0;
            stageRrQuality[i] = 0.0f;
        }
    }

    // -------------------------------------------------------------------------
    // recordStage(stageResult)
    //
    // Called by TestOrchestrator when a stage finishes.
    // Copies the stage summary into our local arrays.
    // -------------------------------------------------------------------------
    function recordStage(stage as StageResult) as Void {
        var idx = stage.stageNumber - 1;  // 0-based
        if (idx < 0 || idx >= 6) { return; }

        stageMeanDfa[idx]   = stage.meanDfaA1;
        stageMeanHr[idx]    = stage.meanHr;
        stageMeanPace[idx]  = stage.meanPace;
        stageMeanPower[idx] = stage.meanPower;
        stageValidity[idx]  = stage.validityScore;
        stageWindows[idx]   = stage.windowCount;
        stageRrQuality[idx] = stage.rrQuality;
        stagesCompleted     = idx + 1;
    }

    // -------------------------------------------------------------------------
    // detect()
    //
    // Runs the LT1 detection algorithm over all recorded stages.
    // Returns a Dictionary with keys:
    //   "detected"       Boolean
    //   "lt1_hr"         Float  (0 if not detected)
    //   "lt1_pace"       Float  (0 if unavailable)
    //   "lt1_power"      Float  (0 if unavailable)
    //   "confidence"     Float  0.0–1.0
    //   "detection_stage" Number  (1-based stage bracket)
    //   "dfa_at_lt1"     Float  (interpolated DFA at LT1 crossing)
    //   "warnings"       Array of String
    // -------------------------------------------------------------------------
    function detect() as Dictionary {
        var warnings = [];

        if (stagesCompleted < 2) {
            warnings.add("Fewer than 2 stages completed");
            return _noDetection(warnings);
        }

        // Find the last stage above 0.75 (stageA) and first stage at/below 0.75 (stageB).
        var stageAIdx = -1;
        var stageBIdx = -1;

        for (var i = 0; i < stagesCompleted; i++) {
            var dfa = stageMeanDfa[i];
            if (dfa < 0.0f) { continue; }  // not computed

            if (dfa > LT1_THRESHOLD) {
                stageAIdx = i;   // keep updating — we want the *last* above
            } else if (stageBIdx == -1 && stageAIdx >= 0) {
                stageBIdx = i;   // first below after the last above
                break;
            }
        }

        // No valid crossing found.
        if (stageAIdx < 0 || stageBIdx < 0) {
            if (stageAIdx < 0) {
                warnings.add("DFA alpha1 never above 0.75 — test may have started too hard");
            } else {
                warnings.add("DFA alpha1 never dropped below 0.75 — test not intense enough");
            }
            return _noDetection(warnings);
        }

        // Check stage validity.
        if (stageWindows[stageAIdx] < MIN_WINDOWS_FOR_VALID_STAGE) {
            warnings.add("Stage " + (stageAIdx + 1) + " has few DFA windows — low reliability");
        }
        if (stageWindows[stageBIdx] < MIN_WINDOWS_FOR_VALID_STAGE) {
            warnings.add("Stage " + (stageBIdx + 1) + " has few DFA windows — low reliability");
        }

        // Interpolate LT1 intensity.
        var dfaA = stageMeanDfa[stageAIdx];
        var dfaB = stageMeanDfa[stageBIdx];
        var dfaRange = dfaB - dfaA;  // negative (dfaB < dfaA)

        // t = how far between stageA and stageB the 0.75 crossing is. t ∈ [0,1].
        var t = (LT1_THRESHOLD - dfaA) / dfaRange;

        var lt1Hr    = stageMeanHr[stageAIdx]    + t * (stageMeanHr[stageBIdx]    - stageMeanHr[stageAIdx]);
        var lt1Pace  = stageMeanPace[stageAIdx]  + t * (stageMeanPace[stageBIdx]  - stageMeanPace[stageAIdx]);
        var lt1Power = stageMeanPower[stageAIdx] + t * (stageMeanPower[stageBIdx] - stageMeanPower[stageAIdx]);

        // Compute confidence score (0.0–1.0).
        var confidence = _computeConfidence(stageAIdx, stageBIdx, dfaRange, warnings);

        // Detection in very early stages is suspicious.
        if ((stageBIdx + 1) < MIN_VALID_DETECTION_STAGE) {
            warnings.add("LT1 detected in stage " + (stageBIdx + 1) + " — test may be too easy");
            confidence *= 0.5f;
        }

        lastResult = {
            "detected"        => true,
            "lt1_hr"          => lt1Hr,
            "lt1_pace"        => lt1Pace > 0.0f ? lt1Pace : 0.0f,
            "lt1_power"       => lt1Power > 0.0f ? lt1Power : 0.0f,
            "confidence"      => confidence,
            "detection_stage" => stageBIdx + 1,  // 1-based stage B
            "dfa_at_lt1"      => LT1_THRESHOLD,
            "warnings"        => warnings
        };
        return lastResult;
    }

    // -------------------------------------------------------------------------
    // _computeConfidence(stageAIdx, stageBIdx, dfaRange, warnings)
    //
    // Produces a 0–1 confidence score from multiple quality signals.
    // Each component contributes independently; they multiply together so that
    // a single very poor signal can significantly lower the overall score.
    // -------------------------------------------------------------------------
    private function _computeConfidence(stageAIdx as Number, stageBIdx as Number,
                                         dfaRange as Float, warnings as Array) as Float {

        // --- Component 1: RR signal quality across the crossing stages ---
        var rrQA = stageRrQuality[stageAIdx];
        var rrQB = stageRrQuality[stageBIdx];
        var rrQMean = (rrQA + rrQB) / 2.0f;
        // Score 0 for quality < 0.5, linear to 1.0 at quality = 1.0.
        var qualComponent = (rrQMean - 0.5f) * 2.0f;
        if (qualComponent < 0.0f) { qualComponent = 0.0f; }
        if (qualComponent > 1.0f) { qualComponent = 1.0f; }

        if (rrQMean < 0.6f) {
            warnings.add("Low RR quality near crossing — consider chest strap");
        }

        // --- Component 2: DFA window count (data volume) ---
        var windowsA = stageWindows[stageAIdx].toFloat();
        var windowsB = stageWindows[stageBIdx].toFloat();
        var windowsMean = (windowsA + windowsB) / 2.0f;
        // 4 windows (2 min valid data) = 1.0; below 2 windows = 0.0.
        var windowComponent = (windowsMean - 1.0f) / 3.0f;
        if (windowComponent < 0.0f) { windowComponent = 0.0f; }
        if (windowComponent > 1.0f) { windowComponent = 1.0f; }

        // --- Component 3: Alpha1 descent slope across all stages ---
        // A steeper, monotone descent through 0.75 gives a sharper LT1 estimate.
        // We reward large |dfaRange| and penalise non-monotone behaviour.
        var slopeComponent = (dfaRange * dfaRange) * 16.0f;  // dfaRange ~ 0.1–0.3 typically
        // dfaRange = -0.25 → slopeComponent = 1.0 (good crossing)
        // dfaRange = -0.10 → slopeComponent = 0.16 (marginal)
        if (slopeComponent > 1.0f) { slopeComponent = 1.0f; }
        slopeComponent = Math.sqrt(slopeComponent);  // soften the penalty

        // Check monotonicity: alpha1 should not increase between stages.
        var nonMonotoneCount = 0;
        for (var i = 1; i < stagesCompleted; i++) {
            if (stageMeanDfa[i] > 0.0f && stageMeanDfa[i - 1] > 0.0f) {
                if (stageMeanDfa[i] > stageMeanDfa[i - 1]) {
                    nonMonotoneCount++;
                }
            }
        }
        var monotonicityComponent = 1.0f - (nonMonotoneCount.toFloat() / stagesCompleted.toFloat()) * 1.5f;
        if (monotonicityComponent < 0.0f) { monotonicityComponent = 0.0f; }
        if (nonMonotoneCount > 0) {
            warnings.add("Alpha1 non-monotone in " + nonMonotoneCount + " stage(s)");
        }

        // --- Combine all components ---
        // Geometric mean keeps the scale [0,1] and ensures any component
        // can pull the score significantly downward.
        var combined = qualComponent * windowComponent * slopeComponent * monotonicityComponent;
        combined = Math.sqrt(Math.sqrt(combined));  // 4th root → geometric mean of 4 factors

        return combined;
    }

    // Helper: build a "not detected" result dictionary.
    private function _noDetection(warnings as Array) as Dictionary {
        return {
            "detected"        => false,
            "lt1_hr"          => 0.0f,
            "lt1_pace"        => 0.0f,
            "lt1_power"       => 0.0f,
            "confidence"      => 0.0f,
            "detection_stage" => -1,
            "dfa_at_lt1"      => -1.0f,
            "warnings"        => warnings
        };
    }

    // Accessor for stage mean DFA (used by FITRecorder for lap fields).
    function getStageMeanDfa(stageIdx as Number) as Float {
        if (stageIdx < 0 || stageIdx >= 6) { return -1.0f; }
        return stageMeanDfa[stageIdx];
    }

    function getStagesCompleted() as Number {
        return stagesCompleted;
    }
}
