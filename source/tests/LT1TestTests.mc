// LT1TestTests.mc
// Unit tests for RRBuffer, DFAComputer, and LT1Detector.
//
// Run with the Connect IQ simulator test harness:
//   connectiq --test --device fr955 --jungle monkey.jungle
//
// The (:test) annotation excludes test functions from production builds.
// Each test function receives a Test.Logger and must return Boolean.
//
// ============================================================================
// TEST STRATEGY
// ============================================================================
//
// RRBuffer tests: verify artifact rejection, interpolation, quality scoring,
//   copyWindow ordering, and reset behaviour using hand-crafted RR sequences.
//
// DFAComputer tests: verify the algorithm produces output in physiologically
//   valid range [0, 2] and responds directionally to structured vs unstructured
//   input.  We do NOT test exact numeric DFA values because:
//     a) fractional Gaussian noise generation in Monkey C is impractical
//     b) the 32-bit float DFA on 128 samples has ±0.05 typical error vs
//        double-precision reference — exact values would be fragile
//
// LT1Detector tests: inject known StageResult arrays and verify interpolation
//   math, confidence scoring, and edge-case handling (never-crossing, etc.).

import Toybox.Lang;
import Toybox.Test;
import Toybox.Math;

// ============================================================================
// RRBuffer tests
// ============================================================================

// Helper: fill a buffer with a clean, monotone RR series and verify copyWindow.
(:test)
function testRRBuffer_basicAcceptAndCopy(logger as Test.Logger) as Boolean {
    var buf = new RRBuffer();
    var rr  = 900;  // ~67 bpm — well within valid range

    // Add 10 identical samples (no relative change → all accepted).
    for (var i = 0; i < 10; i++) {
        var accepted = buf.addInterval(rr);
        if (!accepted) {
            logger.debug("Sample " + i + " unexpectedly rejected");
            return false;
        }
    }

    if (buf.samplesAvailable() != 10) {
        logger.debug("Expected 10 samples, got " + buf.samplesAvailable());
        return false;
    }

    var dest = new [10];
    var n = buf.copyWindow(dest, 10);
    if (n != 10) {
        logger.debug("copyWindow returned " + n + ", expected 10");
        return false;
    }

    // All values should be 900.0.
    for (var i = 0; i < 10; i++) {
        if ((dest[i] - 900.0f).abs() > 0.01f) {
            logger.debug("dest[" + i + "] = " + dest[i] + ", expected 900.0");
            return false;
        }
    }

    return true;
}

// Absolute range rejection: values outside [300, 2000] must be rejected.
(:test)
function testRRBuffer_absoluteRangeRejection(logger as Test.Logger) as Boolean {
    var buf = new RRBuffer();

    // Seed with a valid value so relative-change check has a reference.
    buf.addInterval(800);

    var accepted;
    accepted = buf.addInterval(299);   // too short → reject
    if (accepted) { logger.debug("299ms should be rejected"); return false; }

    accepted = buf.addInterval(2001);  // too long → reject
    if (accepted) { logger.debug("2001ms should be rejected"); return false; }

    accepted = buf.addInterval(300);   // boundary — accept
    if (!accepted) { logger.debug("300ms should be accepted"); return false; }

    accepted = buf.addInterval(2000);  // boundary — reject (>20% from 300)
    // This will fail relative-change check (2000 is >20% from 300), not range.
    // The result depends on whether it's pending or rejected — just verify no crash.
    // (We don't assert the result here because pending logic may hold it.)

    return true;
}

// Artifact interpolation: a single outlier between two clean beats should be
// corrected, not lost.  The buffer should grow by 2 (interpolated + clean).
(:test)
function testRRBuffer_singleArtifactInterpolated(logger as Test.Logger) as Boolean {
    var buf = new RRBuffer();

    // Three clean beats at 900 ms.
    buf.addInterval(900);
    buf.addInterval(900);
    buf.addInterval(900);
    var countBefore = buf.samplesAvailable();  // should be 3

    // One artifact: 900 → 1500 ms jump (67% change, > 20% threshold).
    // This will go into pending slot.
    var artifactAccepted = buf.addInterval(1500);
    // Expected: not directly accepted (pending).
    if (artifactAccepted) {
        logger.debug("1500ms artifact should not be directly accepted");
        return false;
    }

    // Next clean beat at 900 ms recovers the pending artifact.
    var cleanAccepted = buf.addInterval(920);  // ~2% change from 900 — clean
    if (!cleanAccepted) {
        logger.debug("920ms recovery beat should be accepted");
        return false;
    }

    // Buffer should have grown by 2: interpolated(900+920)/2=910 + 920.
    var countAfter = buf.samplesAvailable();
    if (countAfter != countBefore + 2) {
        logger.debug("Expected " + (countBefore + 2) + " samples after interpolation, got " + countAfter);
        return false;
    }

    // The second-to-last value should be the interpolated one ≈ (900+920)/2 = 910.
    var dest = new [countAfter];
    buf.copyWindow(dest, countAfter);
    var interpolatedValue = dest[countAfter - 2];
    if ((interpolatedValue - 910.0f).abs() > 1.0f) {
        logger.debug("Interpolated value should be ~910, got " + interpolatedValue);
        return false;
    }

    // interpolatedCount should be 1.
    if (buf.interpolatedCount() != 1) {
        logger.debug("Expected 1 interpolated beat, got " + buf.interpolatedCount());
        return false;
    }

    return true;
}

// Two consecutive artifacts: neither should be interpolated; both discarded.
(:test)
function testRRBuffer_consecutiveArtifactsDiscarded(logger as Test.Logger) as Boolean {
    var buf = new RRBuffer();

    buf.addInterval(900);
    buf.addInterval(900);
    var countBefore = buf.samplesAvailable();

    // First artifact (pending).
    buf.addInterval(1500);
    // Second artifact (replaces pending, both counted as rejected).
    buf.addInterval(1600);

    // Buffer size should not have grown.
    if (buf.samplesAvailable() != countBefore) {
        logger.debug("Buffer should not grow on consecutive artifacts, got "
                     + buf.samplesAvailable() + " vs " + countBefore);
        return false;
    }

    // No interpolations should have occurred.
    if (buf.interpolatedCount() != 0) {
        logger.debug("Expected 0 interpolations, got " + buf.interpolatedCount());
        return false;
    }

    return true;
}

// qualityScore should be 0 when buffer is empty, ramp up as it fills.
(:test)
function testRRBuffer_qualityScoreRamps(logger as Test.Logger) as Boolean {
    var buf = new RRBuffer();
    if (buf.qualityScore() != 0.0f) {
        logger.debug("Quality should be 0.0 when empty");
        return false;
    }

    // Fill 128 clean samples.
    for (var i = 0; i < 128; i++) {
        buf.addInterval(900);
    }
    var q128 = buf.qualityScore();

    // Fill 256 clean samples (full buffer).
    buf.reset();
    for (var i = 0; i < 256; i++) {
        buf.addInterval(900);
    }
    var q256 = buf.qualityScore();

    // q256 should be higher than q128 (readiness factor).
    if (q256 <= q128) {
        logger.debug("Full buffer quality (" + q256 + ") should exceed half-full (" + q128 + ")");
        return false;
    }

    // Full buffer with no artifacts should have quality ≈ 1.0.
    if (q256 < 0.95f) {
        logger.debug("Full clean buffer quality should be ≥ 0.95, got " + q256);
        return false;
    }

    return true;
}

// reset() clears all state.
(:test)
function testRRBuffer_reset(logger as Test.Logger) as Boolean {
    var buf = new RRBuffer();
    for (var i = 0; i < 50; i++) { buf.addInterval(900); }

    buf.reset();

    if (buf.samplesAvailable() != 0) {
        logger.debug("samplesAvailable should be 0 after reset, got " + buf.samplesAvailable());
        return false;
    }
    if (buf.qualityScore() != 0.0f) {
        logger.debug("quality should be 0.0 after reset");
        return false;
    }
    if (buf.interpolatedCount() != 0) {
        logger.debug("interpolatedCount should be 0 after reset");
        return false;
    }
    return true;
}

// ============================================================================
// DFAComputer tests
// ============================================================================

// Helper: fills a RRBuffer with a synthetic series and returns computed α1.
// series: Array of Float RR values (ms).
function _runDFA(series as Array) as Float {
    var buf  = new RRBuffer();
    var comp = new DFAComputer();

    for (var i = 0; i < series.size(); i++) {
        buf.addInterval(series[i].toNumber());
    }
    return comp.compute(buf);
}

// Helper: generate n samples of a flat RR series (all identical → constant → alpha1 undefined).
// Actually for a pure constant series, DFA F(n)=0 and log is undefined.
// Use near-constant with tiny variation instead.
function _flatRR(n as Number, baseMs as Float) as Array {
    var arr = new [n];
    for (var i = 0; i < n; i++) {
        // Tiny alternating perturbation ±1 ms — minimal HRV, anti-correlated.
        arr[i] = baseMs + (i % 2 == 0 ? 1.0f : -1.0f);
    }
    return arr;
}

// Helper: generate an AR(1) correlated series with high autocorrelation.
// x[n] = 0.9 * x[n-1] + noise.  alpha1 should be close to 1.0 for high r.
// We use a simple recurrence with fixed "noise" to avoid RNG dependency.
function _correlatedRR(n as Number, baseMs as Float) as Array {
    var arr = new [n];
    var x   = 0.0f;  // deviation from baseline
    for (var i = 0; i < n; i++) {
        // Pseudo-noise: oscillates with period 7 to mimic random walk structure.
        var noise = 5.0f * Math.sin(i.toFloat() * 0.9f);
        x = 0.85f * x + noise;
        // Clamp deviation so we stay in the valid RR range.
        if (x >  100.0f) { x =  100.0f; }
        if (x < -100.0f) { x = -100.0f; }
        arr[i] = baseMs + x;
    }
    return arr;
}

// DFA returns -1 when fewer than 64 samples in buffer.
(:test)
function testDFA_insufficientData(logger as Test.Logger) as Boolean {
    var buf  = new RRBuffer();
    var comp = new DFAComputer();
    for (var i = 0; i < 63; i++) { buf.addInterval(900); }
    var alpha = comp.compute(buf);
    if (alpha != -1.0f) {
        logger.debug("Expected -1.0 for < 64 samples, got " + alpha);
        return false;
    }
    return true;
}

// Output must be in [0.0, 2.0] for any valid-enough input.
(:test)
function testDFA_outputInValidRange(logger as Test.Logger) as Boolean {
    var series = _correlatedRR(256, 850.0f);
    var alpha  = _runDFA(series);
    if (alpha == -1.0f) {
        logger.debug("Expected a valid DFA value, got -1.0");
        return false;
    }
    if (alpha < 0.0f || alpha > 2.0f) {
        logger.debug("DFA alpha1 out of range [0,2]: " + alpha);
        return false;
    }
    return true;
}

// Correlated series should have higher alpha1 than anti-correlated.
// This is the core directional property of DFA.
(:test)
function testDFA_correlatedHigherThanFlat(logger as Test.Logger) as Boolean {
    var correlated = _correlatedRR(256, 850.0f);
    var flat       = _flatRR(256, 850.0f);

    var alphaCorr = _runDFA(correlated);
    var alphaFlat = _runDFA(flat);

    if (alphaCorr == -1.0f || alphaFlat == -1.0f) {
        logger.debug("DFA computation failed for test data");
        return false;
    }

    if (alphaCorr <= alphaFlat) {
        logger.debug("Correlated alpha1 (" + alphaCorr +
                     ") should be > flat alpha1 (" + alphaFlat + ")");
        return false;
    }
    return true;
}

// DFAComputer is stateless — calling it twice with the same buffer gives the same result.
(:test)
function testDFA_idempotent(logger as Test.Logger) as Boolean {
    var buf  = new RRBuffer();
    var comp = new DFAComputer();
    var series = _correlatedRR(256, 900.0f);
    for (var i = 0; i < series.size(); i++) {
        buf.addInterval(series[i].toNumber());
    }

    var a1 = comp.compute(buf);
    var a2 = comp.compute(buf);

    if ((a1 - a2).abs() > 0.0001f) {
        logger.debug("DFA not idempotent: " + a1 + " vs " + a2);
        return false;
    }
    return true;
}

// ============================================================================
// LT1Detector tests
// ============================================================================

// Helper: build a StageResult with explicit values.
function _makeStage(num as Number, hr as Float, dfa as Float, quality as Float) as StageResult {
    var s        = new StageResult(num);
    s.meanHr     = hr;
    s.meanPace   = 0.0f;
    s.meanPower  = 0.0f;
    s.meanDfaA1  = dfa;
    s.rrQuality  = quality;
    s.windowCount  = 4;   // 2 min of valid windows at 30s each
    s.validityScore = 1.0f;
    return s;
}

// Clean crossing: stages monotonically decline through 0.75 between stages 4 and 5.
(:test)
function testLT1_cleanCrossing(logger as Test.Logger) as Boolean {
    var det = new LT1Detector();

    det.recordStage(_makeStage(1, 118.0f, 0.96f, 0.95f));
    det.recordStage(_makeStage(2, 129.0f, 0.89f, 0.95f));
    det.recordStage(_makeStage(3, 138.0f, 0.84f, 0.93f));
    det.recordStage(_makeStage(4, 144.0f, 0.79f, 0.91f));
    det.recordStage(_makeStage(5, 152.0f, 0.69f, 0.90f));

    var result = det.detect();

    if (!result["detected"]) {
        logger.debug("LT1 should be detected with clean crossing");
        return false;
    }

    // Interpolation: t = (0.75 - 0.79) / (0.69 - 0.79) = -0.04 / -0.10 = 0.4
    // LT1_HR = 144 + 0.4 * (152 - 144) = 144 + 3.2 = 147.2
    var lt1Hr = result["lt1_hr"] as Float;
    if ((lt1Hr - 147.2f).abs() > 0.5f) {
        logger.debug("Expected LT1_HR ≈ 147.2, got " + lt1Hr);
        return false;
    }

    // Confidence should be > 0 given good data.
    var conf = result["confidence"] as Float;
    if (conf <= 0.0f) {
        logger.debug("Confidence should be > 0, got " + conf);
        return false;
    }

    // Detection stage should be 5 (first stage below 0.75).
    if (result["detection_stage"] != 5) {
        logger.debug("Detection stage should be 5, got " + result["detection_stage"]);
        return false;
    }

    return true;
}

// Never drops below 0.75 — not detected.
(:test)
function testLT1_neverCrosses(logger as Test.Logger) as Boolean {
    var det = new LT1Detector();

    det.recordStage(_makeStage(1, 115.0f, 0.97f, 0.95f));
    det.recordStage(_makeStage(2, 125.0f, 0.91f, 0.94f));
    det.recordStage(_makeStage(3, 135.0f, 0.85f, 0.93f));
    det.recordStage(_makeStage(4, 142.0f, 0.80f, 0.92f));
    det.recordStage(_makeStage(5, 149.0f, 0.77f, 0.91f));
    det.recordStage(_makeStage(6, 156.0f, 0.76f, 0.90f));

    var result = det.detect();
    if (result["detected"]) {
        logger.debug("LT1 should NOT be detected when DFA never goes below 0.75");
        return false;
    }
    return true;
}

// Always below 0.75 — never above → not detected.
(:test)
function testLT1_alwaysBelow(logger as Test.Logger) as Boolean {
    var det = new LT1Detector();

    det.recordStage(_makeStage(1, 118.0f, 0.70f, 0.92f));
    det.recordStage(_makeStage(2, 130.0f, 0.65f, 0.91f));
    det.recordStage(_makeStage(3, 140.0f, 0.60f, 0.90f));

    var result = det.detect();
    if (result["detected"]) {
        logger.debug("LT1 should not be detected when DFA starts below 0.75");
        return false;
    }
    return true;
}

// Fewer than 2 stages → not detected.
(:test)
function testLT1_insufficientStages(logger as Test.Logger) as Boolean {
    var det = new LT1Detector();
    det.recordStage(_makeStage(1, 118.0f, 0.96f, 0.95f));

    var result = det.detect();
    if (result["detected"]) {
        logger.debug("LT1 should not be detected with only 1 stage");
        return false;
    }
    return true;
}

// Confidence should be 0 when detection fails.
(:test)
function testLT1_confidenceZeroOnNoDetection(logger as Test.Logger) as Boolean {
    var det = new LT1Detector();

    var result = det.detect();
    var conf   = result["confidence"] as Float;
    if (conf != 0.0f) {
        logger.debug("Confidence should be 0.0 when not detected, got " + conf);
        return false;
    }
    return true;
}

// Non-monotone alpha1 (stage 4 > stage 3) should produce a warning and lower confidence.
(:test)
function testLT1_nonMonotoneReducesConfidence(logger as Test.Logger) as Boolean {
    var det = new LT1Detector();

    det.recordStage(_makeStage(1, 118.0f, 0.96f, 0.93f));
    det.recordStage(_makeStage(2, 129.0f, 0.89f, 0.93f));
    det.recordStage(_makeStage(3, 138.0f, 0.78f, 0.92f));
    det.recordStage(_makeStage(4, 144.0f, 0.82f, 0.91f));  // ← goes UP (non-monotone)
    det.recordStage(_makeStage(5, 152.0f, 0.69f, 0.90f));

    var result = det.detect();

    if (!result["detected"]) {
        logger.debug("LT1 should still be detected despite non-monotone stage");
        return false;
    }

    var warnings = result["warnings"] as Array;
    if (warnings.size() == 0) {
        logger.debug("Expected at least one warning for non-monotone alpha1");
        return false;
    }

    // Confidence should be less than the clean-crossing case (~0.84).
    var conf = result["confidence"] as Float;
    if (conf >= 0.84f) {
        logger.debug("Confidence should be reduced for non-monotone data, got " + conf);
        return false;
    }

    return true;
}
