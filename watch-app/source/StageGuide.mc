// StageGuide.mc
// Computes per-stage target HR ranges, RPE cues, and relative power guidance.
//
// HR targets are expressed as %HRmax fractions and converted to absolute bpm
// using the athlete's HRmax (from UserProfile HR zones or 220-age estimate).
//
// Power guidance is relative: after stage 1 establishes a power baseline,
// subsequent stages show an estimated watt target based on a ~5% increment
// per stage. This is sport-physiology convention for a step test where each
// stage represents a ~3-4% VO2 increase.
//
// Stage protocol (v1):
//   Stage 1 → very easy (50–55% HRmax)  — well below LT1
//   Stage 2 → easy     (58–63% HRmax)  — light aerobic
//   Stage 3 → moderate (65–69% HRmax)  — mid aerobic
//   Stage 4 → upper    (72–76% HRmax)  — approaching LT1
//   Stage 5 → near LT1 (78–83% HRmax)  — target zone for crossing
//   Stage 6 → above LT1 (84–89% HRmax) — confirm full crossing
//
// Source: Seiler 2010, Stöggl & Sperlich 2015 on step-test intensity design.

import Toybox.Lang;
import Toybox.UserProfile;

class StageGuide {

    // HR target ranges as [%HRmax_low, %HRmax_high] for stages 1–6 (index 0–5).
    // Values chosen to bracket the typical LT1 zone in stages 4–5.
    private const STAGE_HR_PCT = [
        [50, 55],   // Stage 1 — very easy
        [58, 63],   // Stage 2 — easy
        [65, 69],   // Stage 3 — moderate aerobic
        [72, 76],   // Stage 4 — upper aerobic
        [78, 83],   // Stage 5 — near LT1
        [84, 89]    // Stage 6 — above LT1
    ];

    // Perceived exertion cues (Borg RPE 6–20 scale category labels).
    private const STAGE_RPE_LABELS = [
        "Very Easy",       // ~RPE 8–9
        "Easy",            // ~RPE 10–11
        "Moderate",        // ~RPE 12–13
        "Somewhat Hard",   // ~RPE 13–14
        "Hard",            // ~RPE 14–16
        "Very Hard"        // ~RPE 16–17
    ];

    private const STAGE_RPE_SHORT = [
        "VEasy",  // stage 1 — Very Easy
        "Easy",   // stage 2 — Easy
        "Mod",    // stage 3 — Moderate
        "Upper",  // stage 4 — Upper aerobic
        "Hard",   // stage 5 — Near LT1
        "VHard"   // stage 6 — Above LT1
    ];

    // Per-stage power multipliers relative to stage 1 baseline.
    // A 5% increment per stage is a conservative step-test design for running power.
    private const STAGE_POWER_MULT = [
        1.00f,  // Stage 1 — baseline
        1.05f,  // Stage 2
        1.11f,  // Stage 3 — ~1.05²
        1.17f,  // Stage 4
        1.23f,  // Stage 5
        1.30f   // Stage 6
    ];

    private var hrMax          as Number;   // absolute max HR in bpm
    private var baselinePowerW as Float;    // stage 1 mean power; 0 = unknown

    // -------------------------------------------------------------------------
    // initialize(hrMax)
    // hrMax: athlete's maximum heart rate in bpm.
    //   Use resolveHRMax() to get this from UserProfile before constructing.
    // -------------------------------------------------------------------------
    function initialize(hrMax_ as Number) {
        hrMax          = hrMax_ > 100 ? hrMax_ : 185;  // fallback if invalid
        baselinePowerW = 0.0f;
    }

    // -------------------------------------------------------------------------
    // resolveHRMax()  [static helper — call before initialize]
    //
    // Attempts to read HRmax from UserProfile HR zones (most accurate —
    // user set this in Garmin Connect settings).  Falls back to 220 − age.
    // Returns an integer HRmax in bpm, or 180 if nothing is available.
    // -------------------------------------------------------------------------
    static function resolveHRMax() as Number {
        // HR zones array: [zone0_low, zone1_low, zone2_low, zone3_low, zone4_low, hrmax]
        // UserProfile.getHeartRateZones returns an Array of zone upper bounds.
        // The last element is effectively HRmax.
        try {
            var zones = UserProfile.getHeartRateZones(UserProfile.HR_ZONE_SPORT_RUNNING);
            if (zones != null && zones.size() >= 5) {
                var topZone = zones[zones.size() - 1];
                if (topZone != null && topZone > 140) {
                    return topZone;
                }
            }
        } catch (ex) {
            // Zone data not available on this device / profile — fall through.
        }

        // Fallback: 220 - age
        try {
            var profile = UserProfile.getProfile();
            if (profile != null && profile.birthYear != null) {
                var currentYear = 2026;   // compile-time constant for this build
                var age = currentYear - profile.birthYear;
                if (age > 10 && age < 100) {
                    return 220 - age;
                }
            }
        } catch (ex) { }

        return 180;  // conservative default
    }

    // -------------------------------------------------------------------------
    // setBaselinePower(watts)
    // Call once after stage 1 completes with stage 1's mean power.
    // -------------------------------------------------------------------------
    function setBaselinePower(watts as Float) as Void {
        if (watts > 10.0f) { baselinePowerW = watts; }
    }

    // -------------------------------------------------------------------------
    // getTargetHrRange(stageNum) → [low_bpm, high_bpm]
    // stageNum is 1-based (1–6).
    // -------------------------------------------------------------------------
    function getTargetHrRange(stageNum as Number) as Array {
        var idx = stageNum - 1;
        if (idx < 0 || idx >= 6) { return [0, 0]; }

        var pcts = STAGE_HR_PCT[idx];
        var low  = (hrMax * pcts[0] / 100.0f).toNumber();
        var high = (hrMax * pcts[1] / 100.0f).toNumber();
        return [low, high];
    }

    // -------------------------------------------------------------------------
    // getRPELabel(stageNum) → String
    // -------------------------------------------------------------------------
    function getRPELabel(stageNum as Number) as String {
        var idx = stageNum - 1;
        if (idx < 0 || idx >= 6) { return ""; }
        return STAGE_RPE_LABELS[idx];
    }

    // -------------------------------------------------------------------------
    // getPowerTarget(stageNum) → Float (watts, 0.0 = unknown)
    // Returns 0.0 if no baseline power has been set (stage 1 not yet complete
    // or no power sensor).
    // -------------------------------------------------------------------------
    function getPowerTarget(stageNum as Number) as Float {
        if (baselinePowerW <= 0.0f) { return 0.0f; }
        var idx = stageNum - 1;
        if (idx < 0 || idx >= 6) { return 0.0f; }
        return baselinePowerW * STAGE_POWER_MULT[idx];
    }

    // -------------------------------------------------------------------------
    // formatTargetLine(stageNum) → String
    // Compact single-line target string for the watch display.
    // Examples:  "130–142 bpm | Easy"
    //            "130–142 bpm | Mod  | 210 W"
    // -------------------------------------------------------------------------
    function formatTargetLine(stageNum as Number) as String {
        var range = getTargetHrRange(stageNum);
        var idx   = stageNum - 1;
        var rpe   = (idx >= 0 && idx < 6) ? STAGE_RPE_SHORT[idx] : getRPELabel(stageNum);
        var power = getPowerTarget(stageNum);

        var line = range[0].toString() + "-" + range[1].toString() + " " + rpe;
        if (power > 0.0f) {
            line = line + " " + power.format("%.0f") + "W";
        }
        return line;
    }

    function getHRMax() as Number { return hrMax; }
}
