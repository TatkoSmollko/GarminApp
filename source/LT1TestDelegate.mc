// LT1TestDelegate.mc
// Handles physical button input on the Forerunner 955.
//
// Phase 2 change: when the user presses START in IDLE state and no chest strap
// has been confirmed, show an optical HR warning confirmation dialog.
// The user can override and proceed anyway; confidence will be capped at 0.30.

import Toybox.Lang;
import Toybox.WatchUi;

class LT1TestDelegate extends WatchUi.BehaviorDelegate {

    private var orchestrator as TestOrchestrator;
    private var view         as LT1TestView;

    function initialize(orch as TestOrchestrator, v as LT1TestView) {
        BehaviorDelegate.initialize();
        orchestrator = orch;
        view         = v;
    }

    function onKey(keyEvent as WatchUi.KeyEvent) as Boolean {
        var key = keyEvent.getKey();

        if (key == WatchUi.KEY_START) {
            _handleStart();
            return true;
        }
        if (key == WatchUi.KEY_ESC) {
            _handleBack();
            return true;
        }
        return false;
    }

    private function _handleStart() as Void {
        switch (orchestrator.state) {
            case STATE_IDLE:
                _startOrWarnOptical();
                break;
            case STATE_WARMUP:
            case STATE_STAGE:
            case STATE_TRANSITION:
                orchestrator.pauseTest();
                break;
            case STATE_PAUSED:
                orchestrator.resumeTest();
                break;
            case STATE_COMPLETE:
                WatchUi.popView(WatchUi.SLIDE_DOWN);
                break;
            default:
                break;
        }
    }

    // -------------------------------------------------------------------------
    // _startOrWarnOptical
    //
    // If a chest strap has been confirmed → start immediately.
    // If optical (or sensor not yet resolved) → show warning dialog first.
    // -------------------------------------------------------------------------
    private function _startOrWarnOptical() as Void {
        if (orchestrator.sensor.isChestStrap) {
            orchestrator.startTest();
            return;
        }

        // Sensor either confirmed optical or not yet resolved.
        // Show a confirmation so the athlete can pair their strap if they forgot.
        WatchUi.pushView(
            new WatchUi.Confirmation("No chest strap. Proceed with optical HR? (low accuracy)"),
            new OpticalWarningDelegate(orchestrator),
            WatchUi.SLIDE_UP
        );
    }

    private function _handleBack() as Void {
        var state = orchestrator.state;
        if (state == STATE_IDLE || state == STATE_COMPLETE) {
            WatchUi.popView(WatchUi.SLIDE_DOWN);
            return;
        }
        WatchUi.pushView(
            new WatchUi.Confirmation("Stop test?"),
            new AbortConfirmDelegate(orchestrator),
            WatchUi.SLIDE_IMMEDIATE
        );
    }
}

// ============================================================================
// OpticalWarningDelegate
// Shown when user starts without a confirmed chest strap.
// ============================================================================
class OpticalWarningDelegate extends WatchUi.ConfirmationDelegate {
    private var orchestrator as TestOrchestrator;

    function initialize(orch as TestOrchestrator) {
        ConfirmationDelegate.initialize();
        orchestrator = orch;
    }

    function onResponse(response as WatchUi.Confirm) as Boolean {
        if (response == WatchUi.CONFIRM_YES) {
            // Proceed — orchestrator's _completeTest() will cap confidence at 0.30.
            orchestrator.startTest();
        }
        // CONFIRM_NO → do nothing, user goes back to IDLE to pair their strap.
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        return true;
    }
}

// ============================================================================
// AbortConfirmDelegate
// Shown when BACK is pressed during an active test.
// ============================================================================
class AbortConfirmDelegate extends WatchUi.ConfirmationDelegate {
    private var orchestrator as TestOrchestrator;

    function initialize(orch as TestOrchestrator) {
        ConfirmationDelegate.initialize();
        orchestrator = orch;
    }

    function onResponse(response as WatchUi.Confirm) as Boolean {
        if (response == WatchUi.CONFIRM_YES) {
            orchestrator.abortTest();
        }
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        return true;
    }
}
