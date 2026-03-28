import Toybox.Lang;
import Toybox.WatchUi;

class LT1TestDelegate extends WatchUi.BehaviorDelegate {

    private var orchestrator as TestOrchestrator;

    function initialize(orch as TestOrchestrator, v as LT1TestView) {
        BehaviorDelegate.initialize();
        orchestrator = orch;
    }

    function onKey(keyEvent as WatchUi.KeyEvent) as Boolean {
        var key = keyEvent.getKey();

        if (key == WatchUi.KEY_START || key == WatchUi.KEY_ENTER) {
            _handleStart();
            return true;
        }
        if (key == WatchUi.KEY_LAP) {
            _handleLap();
            return true;
        }
        if (key == WatchUi.KEY_ESC) {
            _handleBack();
            return true;
        }
        return false;
    }

    function onMenu() as Boolean {
        if (orchestrator.state == STATE_IDLE || orchestrator.state == STATE_COMPLETE) {
            return false;
        }
        _handleBack();
        return true;
    }

    function onSelect() as Boolean {
        _handleStart();
        return true;
    }

    function onBack() as Boolean {
        _handleBack();
        return true;
    }

    private function _handleStart() as Void {
        switch (orchestrator.state) {
            case STATE_IDLE:
                orchestrator.startTest();
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

    // LAP button — skip warmup or current stage, move to the next phase.
    // Ignored when the test has not started yet or is already complete.
    private function _handleLap() as Void {
        var s = orchestrator.state;
        if (s == STATE_WARMUP || s == STATE_STAGE || s == STATE_TRANSITION) {
            orchestrator.skipToNextStage();
        }
    }

    private function _handleBack() as Void {
        var state = orchestrator.state;

        if (state == STATE_IDLE || state == STATE_COMPLETE) {
            WatchUi.popView(WatchUi.SLIDE_DOWN);
            return;
        }

        // Keep exit handling deterministic on-device:
        // BACK during an active or paused test finishes the session and saves it.
        orchestrator.stopTest();
    }
}
