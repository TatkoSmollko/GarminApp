// ResultModel.mc
// Defines the final result structure produced after the LT1 step test.
// This model is the single source of truth shared between the FIT recorder,
// the end-of-test view, and the JSON export payload.

import Toybox.Lang;

// Per-stage summary collected during the test.
// Indexed 0..5 for stages 1..6.
class StageResult {
    var stageNumber   as Number;     // 1-based stage number
    var meanHr        as Float;      // beats per minute, average over valid window
    var meanPace      as Float;      // seconds per meter (0.0 if unavailable)
    var meanPower     as Float;      // watts (0.0 if unavailable)
    var meanDfaA1     as Float;      // average DFA α1 in valid window
    var validityScore as Float;      // 0.0–1.0: fraction of valid RR windows in stage
    var rrQuality     as Float;      // 0.0–1.0: mean RR quality across stage
    var windowCount   as Number;     // how many DFA windows contributed

    function initialize(num as Number) {
        stageNumber   = num;
        meanHr        = 0.0f;
        meanPace      = 0.0f;
        meanPower     = 0.0f;
        meanDfaA1     = -1.0f;   // -1 = not computed
        validityScore = 0.0f;
        rrQuality     = 0.0f;
        windowCount   = 0;
    }
}

// Top-level result returned after the complete test.
class LT1Result {
    // --- Detected thresholds ---
    var lt1Hr        as Float;   // heart rate at LT1 in bpm (0 = not detected)
    var lt1Pace      as Float;   // pace at LT1 in s/m (0 = unavailable)
    var lt1Power     as Float;   // power at LT1 in watts (0 = unavailable)

    // --- Detection metadata ---
    var confidenceScore    as Float;  // 0.0–1.0 overall confidence
    var detectionStage     as Number; // 1-6 stage where LT1 was interpolated (-1 = none)
    var dfaA1AtDetection   as Float;  // actual DFA α1 value at the LT1 estimate
    var signalQualityOverall as Float; // mean RR quality across entire test

    // --- Per-stage breakdown ---
    var stages as Array;              // Array of StageResult, length = stagesCompleted

    // --- HR source info ---
    var hrSourceIsChestStrap as Boolean;  // true = ANT+ chest strap confirmed
    var hrSourceConfidence   as Float;    // 0.0–1.0 sensor source confidence

    // --- Protocol info ---
    var testProtocolVersion as Number;    // integer version, currently 1
    var testDurationSecs    as Number;    // total elapsed seconds

    function initialize() {
        lt1Hr               = 0.0f;
        lt1Pace             = 0.0f;
        lt1Power            = 0.0f;
        confidenceScore     = 0.0f;
        detectionStage      = -1;
        dfaA1AtDetection    = -1.0f;
        signalQualityOverall = 0.0f;
        stages              = new Array[6];
        hrSourceIsChestStrap = false;
        hrSourceConfidence  = 0.0f;
        testProtocolVersion = 1;
        testDurationSecs    = 0;
    }

    // Returns true if LT1 was successfully estimated.
    function isDetected() as Boolean {
        return lt1Hr > 0.0f;
    }

    // Human-readable confidence label for display.
    function confidenceLabel() as String {
        if (confidenceScore >= 0.75f) { return "High"; }
        if (confidenceScore >= 0.45f) { return "Medium"; }
        return "Low";
    }

    // Serialise to a Dictionary for JSON-compatible export.
    // The mobile app / backend reads this from the app's object store or
    // from developer fields in the FIT file.
    function toExportDict() as Dictionary {
        var stageList = [];
        for (var i = 0; i < stages.size(); i++) {
            var s = stages[i] as StageResult;
            if (s != null) {
                stageList.add({
                    "stage_number"   => s.stageNumber,
                    "mean_hr_bpm"    => s.meanHr,
                    "mean_pace_sm"   => s.meanPace,
                    "mean_power_w"   => s.meanPower,
                    "mean_dfa_a1"    => s.meanDfaA1,
                    "validity_score" => s.validityScore,
                    "rr_quality"     => s.rrQuality,
                    "window_count"   => s.windowCount
                });
            }
        }

        return {
            "schema_version"         => "1.0",
            "test_protocol_version"  => testProtocolVersion,
            "test_duration_secs"     => testDurationSecs,
            "lt1_hr_bpm"             => lt1Hr,
            "lt1_pace_sm"            => lt1Pace,
            "lt1_power_w"            => lt1Power,
            "confidence_score"       => confidenceScore,
            "detection_stage"        => detectionStage,
            "dfa_a1_at_detection"    => dfaA1AtDetection,
            "signal_quality_overall" => signalQualityOverall,
            "hr_source_chest_strap"  => hrSourceIsChestStrap,
            "hr_source_confidence"   => hrSourceConfidence,
            "stages"                 => stageList
        };
    }
}
