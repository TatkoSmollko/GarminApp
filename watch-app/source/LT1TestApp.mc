// LT1TestApp.mc
// Application entry point.
//
// Phase 2 changes:
//   - Sensor starts immediately on app launch (not at test start) so the
//     source-detection logic (chest strap vs optical) has time to resolve
//     before the user presses START.  The Idle screen then shows the
//     accurate source badge.
//   - StageGuide is constructed here with HRmax from UserProfile.
//   - orchestrator.onStateChange wired to request a UI update.

import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

class LT1TestApp extends Application.AppBase {

    private var rrBuffer      as RRBuffer or Null;
    private var sensor        as SensorLayer or Null;
    private var dfaComputer   as DFAComputer or Null;
    private var lt1Detector   as LT1Detector or Null;
    private var fitRecorder   as FITRecorder or Null;
    private var stageGuide    as StageGuide or Null;
    private var uploadManager as UploadManager or Null;
    private var orchestrator  as TestOrchestrator or Null;

    private var mainView     as LT1TestView or Null;
    private var mainDelegate as LT1TestDelegate or Null;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Dictionary?) as Void {
        // ---- Construct all modules bottom-up ----
        rrBuffer      = new RRBuffer();
        uploadManager = new UploadManager();
        sensor        = new SensorLayer(rrBuffer, uploadManager);
        dfaComputer   = new DFAComputer();
        lt1Detector   = new LT1Detector();
        fitRecorder   = new FITRecorder();

        // Resolve HRmax from UserProfile (best-effort; falls back gracefully).
        var hrMax   = StageGuide.resolveHRMax();
        stageGuide  = new StageGuide(hrMax);

        orchestrator = new TestOrchestrator(
            sensor, rrBuffer, dfaComputer, lt1Detector,
            fitRecorder, stageGuide, uploadManager
        );

        mainView     = new LT1TestView(orchestrator);
        mainDelegate = new LT1TestDelegate(orchestrator, mainView);

        // Wire orchestrator state changes to UI refresh.
        orchestrator.onStateChange = method(:_onOrchestratorUpdate);

        // Start sensor early so chest-strap detection resolves on idle screen.
        sensor.start();

        // Retry any upload that failed in a previous session (no BT at that time).
        uploadManager.attemptPendingUpload();
    }

    function onStop(state as Dictionary?) as Void {
        if (sensor != null) { sensor.stop(); }
        if (fitRecorder != null && fitRecorder.isActive()) {
            fitRecorder.discardSession();
        }
    }

    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        return [mainView, mainDelegate];
    }

    function _onOrchestratorUpdate() as Void {
        WatchUi.requestUpdate();
    }
}
