// TestOrchestrator.mc
// Controls the full LT1 step test lifecycle via a state machine.
//
// ============================================================================
// TEST PROTOCOL (v1)
// ============================================================================
//
// STATE_IDLE      : app opened, waiting for user to press START
// STATE_WARMUP    : 10 min easy running, sensor stabilisation
//                   DFA is computed but not used for LT1 detection
// STATE_STAGE(1–6): 4 min stages of increasing intensity
//                   First 2 min: "settling" — data collected, not used for LT1
//                   Last 2 min: "analysis window" — DFA used for stage mean
// STATE_TRANSITION: 30 s between stages — prompt for next intensity
// STATE_COMPLETE  : test finished, result computed, summary shown
// STATE_PAUSED    : user paused mid-test
//
// Phase 2 additions:
//   - StageGuide provides HR target ranges and RPE cues per stage
//   - AppStorage persists the final result so the mobile companion can read it
//   - sensor is now a public var so the View and Delegate can read it directly

import Toybox.Lang;
import Toybox.Timer;
import Toybox.WatchUi;
import Toybox.Application;

// Orchestrator state constants.
enum OrchestratorState {
    STATE_IDLE       = 0,
    STATE_WARMUP     = 1,
    STATE_STAGE      = 2,
    STATE_TRANSITION = 3,
    STATE_COMPLETE   = 4,
    STATE_PAUSED     = 5
}

class TestOrchestrator {

    // ---- Protocol configuration ----
    private const WARMUP_DURATION_S      = 600;   // 10 minutes
    private const STAGE_DURATION_S       = 240;   //  4 minutes
    private const TRANSITION_DURATION_S  = 30;    // 30 seconds between stages
    private const NUM_STAGES             = 6;
    private const SETTLING_DURATION_S    = 120;   // 2 minutes settling per stage
    private const DFA_UPDATE_INTERVAL_MS = 30000; // 30 seconds

    // AppStorage key — the Connect IQ companion app reads this key after sync.
    private const STORAGE_KEY_LAST_RESULT = "lt1_last_result";

    // ---- Module references ----
    // sensor is public so View and Delegate can read HR, isChestStrap, etc.
    var sensor          as SensorLayer;
    private var rrBuffer    as RRBuffer;
    private var dfaComputer as DFAComputer;
    private var lt1Detector as LT1Detector;
    private var fitRecorder as FITRecorder;
    var stageGuide      as StageGuide;   // public — View reads targets

    // ---- State machine ----
    var state          as OrchestratorState;
    var currentStage   as Number;    // 1–6 (0 during warmup)
    var stageElapsed   as Number;    // seconds elapsed in current state

    // ---- Per-stage accumulators (analysis window only) ----
    private var stageHrAccum     as Float or Null;
    private var stagePaceAccum   as Float or Null;
    private var stagePowerAccum  as Float or Null;
    private var stageDfaAccum    as Float or Null;
    private var stageQualAccum   as Float or Null;
    private var stageWindowCount  as Number or Null;  // all 30s windows in stage
    private var stageValidWindows as Number or Null;  // windows in valid analysis window

    // ---- Global quality accumulator ----
    private var totalQualAccum   as Float;
    private var totalQualSamples as Number;
    private var testStartSecs    as Number;   // for testDurationSecs

    // ---- Stage results ----
    private var stageResults as Array;   // StageResult[6]

    // ---- Timers ----
    private var secondTimer as Timer.Timer;
    private var dfaTimer    as Timer.Timer;

    // ---- Pause / resume ----
    private var stateBeforePause as OrchestratorState;
    private var lastFinalisedStage as Number;

    // ---- Output ----
    var finalResult as LT1Result or Null;

    // ---- Callbacks ----
    var onStateChange as Method or Null;  // notified on state transitions

    // live DFA value for the view (updated each DFA tick)
    var latestDfa as Float;

    function initialize(sensor_      as SensorLayer,
                        rrBuffer_    as RRBuffer,
                        dfaComputer_ as DFAComputer,
                        lt1Detector_ as LT1Detector,
                        fitRecorder_ as FITRecorder,
                        stageGuide_  as StageGuide) {
        sensor      = sensor_;
        rrBuffer    = rrBuffer_;
        dfaComputer = dfaComputer_;
        lt1Detector = lt1Detector_;
        fitRecorder = fitRecorder_;
        stageGuide  = stageGuide_;

        state              = STATE_IDLE;
        currentStage       = 0;
        stageElapsed       = 0;
        stateBeforePause   = STATE_IDLE;
        finalResult        = null;
        onStateChange      = null;
        latestDfa          = -1.0f;
        testStartSecs      = 0;
        lastFinalisedStage = 0;

        stageResults = new [NUM_STAGES];
        for (var i = 0; i < NUM_STAGES; i++) {
            stageResults[i] = new StageResult(i + 1);
        }

        _resetStageAccumulators();
        totalQualAccum   = 0.0f;
        totalQualSamples = 0;

        secondTimer = new Timer.Timer();
        dfaTimer    = new Timer.Timer();
    }

    // =========================================================================
    // Public control interface
    // =========================================================================

    function startTest() as Void {
        if (state != STATE_IDLE) { return; }

        _resetTestState();
        rrBuffer.reset();

        // Sensor may already be running (started in onStart for source detection).
        // start() is idempotent.
        sensor.start();

        var ok = fitRecorder.startSession();
        if (!ok) {
            // Another activity is running — bail out.
            // TODO: push a WatchUi.Alert here in a future polish pass.
            return;
        }

        sensor.restartForActivitySession();

        _enterWarmup();
    }

    function pauseTest() as Void {
        if (state == STATE_IDLE || state == STATE_COMPLETE || state == STATE_PAUSED) {
            return;
        }
        stateBeforePause = state;
        state = STATE_PAUSED;
        secondTimer.stop();
        dfaTimer.stop();
        _notifyStateChange();
    }

    function resumeTest() as Void {
        if (state != STATE_PAUSED) { return; }
        state = stateBeforePause;
        _startTimers();
        _notifyStateChange();
    }

    function stopTest() as Void {
        secondTimer.stop();
        dfaTimer.stop();
        sensor.stop();
        _completeTest();
    }

    // -------------------------------------------------------------------------
    // skipToNextStage()
    //
    // Called when the athlete presses the LAP button during a test.
    // Immediately advances to the next phase without waiting for the timer:
    //   Warmup     → Stage 1
    //   Stage N    → Transition  (or Complete if it was the last stage)
    //   Transition → Stage N+1
    //
    // Stage data accumulated so far is still finalised normally so no data
    // is lost — the stage will simply have fewer analysis windows.
    // -------------------------------------------------------------------------
    function skipToNextStage() as Void {
        switch (state) {
            case STATE_WARMUP:
                // Stop both timers; _enterStage will restart them.
                secondTimer.stop();
                dfaTimer.stop();
                _enterStage(1);
                break;

            case STATE_STAGE:
                // _enterTransition handles timer teardown + _finaliseCurrentStage.
                // stopTest handles it for the last stage.
                if (currentStage < NUM_STAGES) {
                    _enterTransition();
                } else {
                    stopTest();
                }
                break;

            case STATE_TRANSITION:
                // Only the secondTimer runs during transition.
                secondTimer.stop();
                _enterStage(currentStage + 1);
                break;

            default:
                break;
        }
    }

    function abortTest() as Void {
        secondTimer.stop();
        dfaTimer.stop();
        sensor.stop();
        finalResult = null;
        fitRecorder.discardSession();
        state = STATE_IDLE;
        currentStage = 0;
        stageElapsed = 0;
        _notifyStateChange();
    }

    // =========================================================================
    // State machine transitions
    // =========================================================================

    private function _enterWarmup() as Void {
        state        = STATE_WARMUP;
        currentStage = 0;
        stageElapsed = 0;
        _startTimers();
        _notifyStateChange();
    }

    private function _enterStage(stageNum as Number) as Void {
        state        = STATE_STAGE;
        currentStage = stageNum;
        stageElapsed = 0;
        _resetStageAccumulators();
        _startTimers();
        _notifyStateChange();
    }

    private function _enterTransition() as Void {
        _finaliseCurrentStage();

        state        = STATE_TRANSITION;
        stageElapsed = 0;
        secondTimer.stop();
        dfaTimer.stop();
        // Transition uses only the second timer (no DFA during rest).
        secondTimer.start(method(:onSecondTick), 1000, true);
        _notifyStateChange();
    }

    private function _completeTest() as Void {
        state = STATE_COMPLETE;

        // Finalise last stage if it was running.
        if (currentStage >= 1 && currentStage <= NUM_STAGES) {
            _finaliseCurrentStage();
        }

        // Run LT1 detection.
        var detection = lt1Detector.detect();

        // Build final result.
        finalResult = new LT1Result();
        finalResult.lt1Hr              = detection["lt1_hr"];
        finalResult.lt1Pace            = detection["lt1_pace"];
        finalResult.lt1Power           = detection["lt1_power"];
        finalResult.confidenceScore    = detection["confidence"];
        finalResult.detectionStage     = detection["detection_stage"];
        finalResult.dfaA1AtDetection   = detection["dfa_at_lt1"];
        finalResult.hrSourceIsChestStrap = sensor.isChestStrap;
        finalResult.hrSourceConfidence  = sensor.sourceConfidence();
        finalResult.testProtocolVersion = 1;
        finalResult.testDurationSecs    = totalQualSamples;  // ~1 s per tick

        if (totalQualSamples > 0) {
            finalResult.signalQualityOverall = totalQualAccum / totalQualSamples.toFloat();
        }

        // Cap confidence when using optical HR (synthetic RR — not valid for DFA).
        if (!sensor.isChestStrap && finalResult.confidenceScore > 0.30f) {
            finalResult.confidenceScore = 0.30f;
        }

        for (var i = 0; i < NUM_STAGES; i++) {
            finalResult.stages[i] = stageResults[i];
        }

        // Write FIT session fields and close the activity.
        fitRecorder.writeSessionFields(finalResult);
        fitRecorder.stopSession();
        sensor.stop();

        // ---- Persist result to AppStorage ----
        // The Connect IQ companion SDK can read Application.Storage values
        // from a paired phone after the watch syncs.  The mobile app picks up
        // STORAGE_KEY_LAST_RESULT on next connect.
        try {
            Application.Storage.setValue(STORAGE_KEY_LAST_RESULT, finalResult.toExportDict());
        } catch (ex) {
            // Storage not available (simulator) — silently skip.
        }

        _notifyStateChange();
    }

    // =========================================================================
    // Timer callbacks
    // =========================================================================

    function onSecondTick() as Void {
        stageElapsed++;
        totalQualAccum   += sensor.rrQuality;
        totalQualSamples++;

        switch (state) {
            case STATE_WARMUP:
                if (stageElapsed >= WARMUP_DURATION_S) { _enterStage(1); }
                break;

            case STATE_STAGE:
                if (stageElapsed >= STAGE_DURATION_S) {
                    if (currentStage < NUM_STAGES) {
                        _enterTransition();
                    } else {
                        stopTest();
                    }
                }
                break;

            case STATE_TRANSITION:
                if (stageElapsed >= TRANSITION_DURATION_S) {
                    _enterStage(currentStage + 1);
                }
                break;

            default:
                break;
        }

        WatchUi.requestUpdate();
    }

    function onDFATick() as Void {
        var dfa     = dfaComputer.compute(rrBuffer);
        var quality = sensor.rrQuality;
        var inAnalysis = state == STATE_STAGE && stageElapsed > SETTLING_DURATION_S;
        var hasValidRR = sensor.canUseRRForDfa();
        var isValid    = inAnalysis && hasValidRR && (dfa > 0.0f) && (quality > 0.5f);
        var stageNum   = (state == STATE_WARMUP) ? 0 : currentStage;

        latestDfa = dfa;

        fitRecorder.writeRecordFields(dfa, quality, stageNum, isValid);

        if (isValid) {
            stageHrAccum    += sensor.currentHr.toFloat();
            stagePaceAccum  += sensor.currentPace;
            stagePowerAccum += sensor.currentPower;
            stageDfaAccum   += dfa;
            stageQualAccum  += quality;
            stageWindowCount++;
            stageValidWindows++;
        } else if (inAnalysis) {
            // Count window but don't use — DFA invalid (poor quality or insufficient data).
            stageWindowCount++;
        }
    }

    // =========================================================================
    // Private helpers
    // =========================================================================

    private function _startTimers() as Void {
        secondTimer.start(method(:onSecondTick), 1000, true);
        dfaTimer.start(method(:onDFATick), DFA_UPDATE_INTERVAL_MS, true);
    }

    private function _resetStageAccumulators() as Void {
        stageHrAccum      = 0.0f;
        stagePaceAccum    = 0.0f;
        stagePowerAccum   = 0.0f;
        stageDfaAccum     = 0.0f;
        stageQualAccum    = 0.0f;
        stageWindowCount  = 0;
        stageValidWindows = 0;
    }

    private function _resetTestState() as Void {
        currentStage = 0;
        stageElapsed = 0;
        stateBeforePause = STATE_IDLE;
        finalResult = null;
        latestDfa = -1.0f;
        totalQualAccum = 0.0f;
        totalQualSamples = 0;
        testStartSecs = 0;
        lastFinalisedStage = 0;
        lt1Detector.reset();

        for (var i = 0; i < NUM_STAGES; i++) {
            stageResults[i] = new StageResult(i + 1);
        }
        _resetStageAccumulators();
    }

    private function _finaliseCurrentStage() as Void {
        if (currentStage < 1 || currentStage > NUM_STAGES) { return; }
        if (currentStage <= lastFinalisedStage) { return; }

        var idx = currentStage - 1;
        var s   = stageResults[idx] as StageResult;

        if (stageValidWindows > 0) {
            var n       = stageValidWindows.toFloat();
            s.meanHr    = stageHrAccum   / n;
            s.meanPace  = stagePaceAccum / n;
            s.meanPower = stagePowerAccum / n;
            s.meanDfaA1 = stageDfaAccum  / n;
            s.rrQuality = stageQualAccum / n;
        }

        s.windowCount   = stageWindowCount;
        s.validityScore = stageWindowCount > 0
            ? stageValidWindows.toFloat() / stageWindowCount.toFloat()
            : 0.0f;

        // After stage 1, set the power baseline for StageGuide.
        if (currentStage == 1 && s.meanPower > 0.0f) {
            stageGuide.setBaselinePower(s.meanPower);
        }

        lt1Detector.recordStage(s);
        fitRecorder.writeLapFields(s);
        fitRecorder.addLap();
        lastFinalisedStage = currentStage;
    }

    private function _notifyStateChange() as Void {
        if (onStateChange != null) { onStateChange.invoke(); }
    }

    // =========================================================================
    // Accessors for View / Delegate
    // =========================================================================

    function stateLabel() as String {
        switch (state) {
            case STATE_IDLE:       return "Ready";
            case STATE_WARMUP:     return "Warmup";
            case STATE_STAGE:      return "Stage " + currentStage;
            case STATE_TRANSITION: return "Rest";
            case STATE_COMPLETE:   return "Done";
            case STATE_PAUSED:     return "Paused";
            default:               return "---";
        }
    }

    function timeRemainingInStage() as Number {
        switch (state) {
            case STATE_WARMUP:     return WARMUP_DURATION_S    - stageElapsed;
            case STATE_STAGE:      return STAGE_DURATION_S     - stageElapsed;
            case STATE_TRANSITION: return TRANSITION_DURATION_S - stageElapsed;
            default:               return 0;
        }
    }

    function isInAnalysisWindow() as Boolean {
        return state == STATE_STAGE && stageElapsed > SETTLING_DURATION_S;
    }

    // Next-stage label shown during transition countdown.
    function nextStageTargetLine() as String {
        if (state != STATE_TRANSITION) { return ""; }
        return stageGuide.formatTargetLine(currentStage + 1);
    }

    // Current-stage target line shown during a stage.
    function currentStageTargetLine() as String {
        if (state != STATE_STAGE && state != STATE_WARMUP) { return ""; }
        if (state == STATE_WARMUP) { return "Easy warmup run"; }
        return stageGuide.formatTargetLine(currentStage);
    }
}
