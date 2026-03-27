// FITRecorder.mc
// Creates and manages a Garmin activity session with custom developer fields.
//
// ============================================================================
// FIT DEVELOPER FIELD DESIGN
// ============================================================================
//
// Field allocation uses FitContributor field numbers 0–14.
// All numbers are local to this app's developer data index.
//
// RECORD fields (written every DFA update, ~30 s):
//   0  dfa_a1            Float   DFA alpha1 value; -1.0 = not computed
//   1  rr_quality_score  Uint8   0–100 integer representation of 0.0–1.0
//   2  current_stage     Uint8   0=warmup, 1–6=stage number
//   3  valid_window_flag Uint8   1 = this window's DFA is considered valid
//
// LAP fields (written once per stage/warmup lap):
//   4  stage_mean_hr        Float   mean HR in bpm over the stage's valid window
//   5  stage_mean_pace_sm   Float   mean pace in seconds/meter (0 = no GPS)
//   6  stage_mean_dfa_a1    Float   mean DFA α1 over valid windows in stage
//   7  stage_validity_score Float   fraction of 30-s windows that were valid
//
// SESSION fields (written once at the end):
//   8  lt1_hr               Float   estimated LT1 HR in bpm (0 = not detected)
//   9  lt1_pace_sm          Float   estimated LT1 pace in s/m (0 = not avail.)
//  10  lt1_power_w          Float   estimated LT1 power in watts (0 = not avail.)
//  11  lt1_confidence       Float   0.0–1.0 detection confidence
//  12  detection_stage      Uint8   stage number where LT1 bracket was found
//  13  signal_quality_overall Float  mean RR quality across the whole test
//  14  test_protocol_version Uint8   currently 1
//
// STANDARD fields (written by the runtime automatically because we use
//   ActivityRecording.createSession with SPORT_RUNNING):
//   heart_rate, distance, speed, cadence, altitude, gps coordinates
//
// Lap boundaries correspond to stage transitions, so in Garmin Connect
//   the lap summary table gives a per-stage breakdown automatically.

import Toybox.Lang;
import Toybox.ActivityRecording;
import Toybox.FitContributor;
import Toybox.Activity;

class FITRecorder {

    // ---- Session ----
    private var session as ActivityRecording.Session or Null;

    // ---- RECORD developer fields ----
    private var fDfaA1         as FitContributor.Field or Null;
    private var fRrQuality     as FitContributor.Field or Null;
    private var fCurrentStage  as FitContributor.Field or Null;
    private var fValidWindow   as FitContributor.Field or Null;

    // ---- LAP developer fields ----
    private var fStageMeanHr      as FitContributor.Field or Null;
    private var fStageMeanPace    as FitContributor.Field or Null;
    private var fStageMeanDfa     as FitContributor.Field or Null;
    private var fStageValidity    as FitContributor.Field or Null;

    // ---- SESSION developer fields ----
    private var fLt1Hr           as FitContributor.Field or Null;
    private var fLt1Pace         as FitContributor.Field or Null;
    private var fLt1Power        as FitContributor.Field or Null;
    private var fLt1Confidence   as FitContributor.Field or Null;
    private var fDetectionStage  as FitContributor.Field or Null;
    private var fSignalQuality   as FitContributor.Field or Null;
    private var fProtocolVersion as FitContributor.Field or Null;

    function initialize() {
        session           = null;
        fDfaA1            = null;
        fRrQuality        = null;
        fCurrentStage     = null;
        fValidWindow      = null;
        fStageMeanHr      = null;
        fStageMeanPace    = null;
        fStageMeanDfa     = null;
        fStageValidity    = null;
        fLt1Hr            = null;
        fLt1Pace          = null;
        fLt1Power         = null;
        fLt1Confidence    = null;
        fDetectionStage   = null;
        fSignalQuality    = null;
        fProtocolVersion  = null;
    }

    // -------------------------------------------------------------------------
    // startSession()
    // Creates the activity session and all developer fields.
    // Must be called before any field writes.
    // -------------------------------------------------------------------------
    function startSession() as Boolean {
        session = ActivityRecording.createSession({
            :sport    => ActivityRecording.SPORT_RUNNING,
            :subSport => ActivityRecording.SUB_SPORT_GENERIC,
            :name     => "LT1 Step Test"
        });

        if (session == null) { return false; }

        // ---- RECORD fields ----
        fDfaA1 = session.createField(
            "dfa_a1", 0, FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "" }
        );
        fRrQuality = session.createField(
            "rr_quality_score", 1, FitContributor.DATA_TYPE_UINT8,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "%" }
        );
        fCurrentStage = session.createField(
            "current_stage", 2, FitContributor.DATA_TYPE_UINT8,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "" }
        );
        fValidWindow = session.createField(
            "valid_window_flag", 3, FitContributor.DATA_TYPE_UINT8,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "" }
        );

        // ---- LAP fields ----
        fStageMeanHr = session.createField(
            "stage_mean_hr", 4, FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_LAP, :units => "bpm" }
        );
        fStageMeanPace = session.createField(
            "stage_mean_pace_sm", 5, FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_LAP, :units => "s/m" }
        );
        fStageMeanDfa = session.createField(
            "stage_mean_dfa_a1", 6, FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_LAP, :units => "" }
        );
        fStageValidity = session.createField(
            "stage_validity_score", 7, FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_LAP, :units => "" }
        );

        // ---- SESSION fields ----
        fLt1Hr = session.createField(
            "lt1_hr", 8, FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "bpm" }
        );
        fLt1Pace = session.createField(
            "lt1_pace_sm", 9, FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "s/m" }
        );
        fLt1Power = session.createField(
            "lt1_power_w", 10, FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "W" }
        );
        fLt1Confidence = session.createField(
            "lt1_confidence", 11, FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "" }
        );
        fDetectionStage = session.createField(
            "detection_stage", 12, FitContributor.DATA_TYPE_UINT8,
            { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "" }
        );
        fSignalQuality = session.createField(
            "signal_quality_overall", 13, FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "" }
        );
        fProtocolVersion = session.createField(
            "test_protocol_version", 14, FitContributor.DATA_TYPE_UINT8,
            { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "" }
        );

        session.start();
        return true;
    }

    // -------------------------------------------------------------------------
    // writeRecordFields(dfaA1, rrQualityFraction, stage, isValid)
    // Call on each DFA update (~30 s).
    // -------------------------------------------------------------------------
    function writeRecordFields(dfaA1 as Float, rrQualityFraction as Float,
                                stage as Number, isValid as Boolean) as Void {
        if (session == null) { return; }

        if (fDfaA1       != null) { fDfaA1.setData(dfaA1); }
        if (fRrQuality   != null) {
            var q = (rrQualityFraction * 100.0f).toNumber();
            fRrQuality.setData(q);
        }
        if (fCurrentStage != null) { fCurrentStage.setData(stage); }
        if (fValidWindow  != null) { fValidWindow.setData(isValid ? 1 : 0); }
    }

    // -------------------------------------------------------------------------
    // writeLapFields(stageResult)
    // Call just before session.addLap() at each stage transition.
    // -------------------------------------------------------------------------
    function writeLapFields(stage as StageResult) as Void {
        if (session == null) { return; }

        if (fStageMeanHr   != null) { fStageMeanHr.setData(stage.meanHr); }
        if (fStageMeanPace != null) { fStageMeanPace.setData(stage.meanPace); }
        if (fStageMeanDfa  != null) { fStageMeanDfa.setData(stage.meanDfaA1); }
        if (fStageValidity != null) { fStageValidity.setData(stage.validityScore); }
    }

    // -------------------------------------------------------------------------
    // addLap()
    // Writes a lap boundary to the FIT file.  This creates a lap record that
    // Garmin Connect uses to display the per-stage summary.
    // Always call writeLapFields BEFORE addLap.
    // -------------------------------------------------------------------------
    function addLap() as Void {
        if (session != null) { session.addLap(); }
    }

    // -------------------------------------------------------------------------
    // writeSessionFields(result)
    // Call once, just before stopSession(), with the final LT1Result.
    // -------------------------------------------------------------------------
    function writeSessionFields(result as LT1Result) as Void {
        if (session == null) { return; }

        if (fLt1Hr          != null) { fLt1Hr.setData(result.lt1Hr); }
        if (fLt1Pace        != null) { fLt1Pace.setData(result.lt1Pace); }
        if (fLt1Power       != null) { fLt1Power.setData(result.lt1Power); }
        if (fLt1Confidence  != null) { fLt1Confidence.setData(result.confidenceScore); }
        if (fDetectionStage != null) {
            var ds = result.detectionStage >= 0 ? result.detectionStage : 0;
            fDetectionStage.setData(ds);
        }
        if (fSignalQuality  != null) { fSignalQuality.setData(result.signalQualityOverall); }
        if (fProtocolVersion != null) { fProtocolVersion.setData(result.testProtocolVersion); }
    }

    // -------------------------------------------------------------------------
    // stopSession()
    // Finalises and saves the activity.
    // -------------------------------------------------------------------------
    function stopSession() as Void {
        if (session == null) { return; }
        session.stop();
        session.save();
        session = null;
    }

    // Discard without saving (user abort).
    function discardSession() as Void {
        if (session == null) { return; }
        session.stop();
        session.discard();
        session = null;
    }

    function isActive() as Boolean {
        return session != null;
    }
}
