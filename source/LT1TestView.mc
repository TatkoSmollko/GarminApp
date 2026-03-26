// LT1TestView.mc
// Main watch display, drawn entirely in onUpdate() via Dc calls.
//
// Screen layout (round 454×454, FR955) — Phase 2:
//
//   ┌──────────────────────────────────────┐
//   │        Stage 3    2:14               │  ← state + remaining
//   │────────────────────────────────────  │
//   │                 142                  │  ← large HR
//   │                 bpm                  │
//   │  DFA α1         0.81    ✓ Analysis   │  ← DFA + window flag
//   │  Target  130–142 bpm | Moderate      │  ← stage guidance (Phase 2)
//   │  LT1     148 bpm            High     │  ← live LT1 estimate
//   │────────────────────────────────────  │
//   │  RR 87%                 CHEST STRAP  │  ← quality + source
//   └──────────────────────────────────────┘
//
//   COMPLETE overlay shows final summary.
//   TRANSITION overlay shows next-stage target.
//   IDLE shows chest-strap status and "Press START".

import Toybox.Lang;
import Toybox.WatchUi;
import Toybox.Graphics;

class LT1TestView extends WatchUi.View {

    private var orchestrator as TestOrchestrator;

    function initialize(orch as TestOrchestrator) {
        View.initialize();
        orchestrator = orch;
    }

    function onLayout(dc as Graphics.Dc) as Void { }

    function onUpdate(dc as Graphics.Dc) as Void {
        var w  = dc.getWidth();
        var h  = dc.getHeight();
        var cx = w / 2;

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        // Route to specialised layouts for IDLE / COMPLETE / TRANSITION.
        var state = orchestrator.state;
        if (state == STATE_IDLE)       { _drawIdle(dc, w, h, cx);       return; }
        if (state == STATE_COMPLETE)   { _drawComplete(dc, w, h, cx);   return; }
        if (state == STATE_TRANSITION) { _drawTransition(dc, w, h, cx); return; }

        // ---- WARMUP / STAGE / PAUSED layout ----
        _drawRunningLayout(dc, w, h, cx);
    }

    // =========================================================================
    // IDLE screen
    // =========================================================================
    private function _drawIdle(dc as Graphics.Dc, w as Number, h as Number, cx as Number) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, 80, Graphics.FONT_MEDIUM, "LT1 Test", Graphics.TEXT_JUSTIFY_CENTER);

        // Sensor source status — resolves within ~3 s of app launch.
        var isStrap   = orchestrator.sensor.isChestStrap;
        var srcLabel  = isStrap ? "Chest Strap ✓" : "No strap detected";
        var srcColour = isStrap ? Graphics.COLOR_GREEN : Graphics.COLOR_YELLOW;
        dc.setColor(srcColour, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, 160, Graphics.FONT_SMALL, srcLabel, Graphics.TEXT_JUSTIFY_CENTER);

        if (!isStrap) {
            dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, 195, Graphics.FONT_TINY, "Use HRM for best results", Graphics.TEXT_JUSTIFY_CENTER);
        }

        // HRmax from StageGuide (confirmed from UserProfile).
        var hrMax = orchestrator.stageGuide.getHRMax();
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, 240, Graphics.FONT_TINY, "HRmax: " + hrMax + " bpm", Graphics.TEXT_JUSTIFY_CENTER);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h - 70, Graphics.FONT_SMALL, "Press START", Graphics.TEXT_JUSTIFY_CENTER);
    }

    // =========================================================================
    // RUNNING layout (Warmup / Stage / Paused)
    // =========================================================================
    private function _drawRunningLayout(dc as Graphics.Dc, w as Number, h as Number, cx as Number) as Void {
        // ---- Top bar: state label + remaining time ----
        var stateStr = orchestrator.stateLabel();
        var timeStr  = _formatMMSS(orchestrator.timeRemainingInStage());
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx - 30, 22, Graphics.FONT_SMALL, stateStr, Graphics.TEXT_JUSTIFY_RIGHT);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx + 30, 22, Graphics.FONT_SMALL, timeStr, Graphics.TEXT_JUSTIFY_LEFT);

        _drawDivider(dc, w, 50);

        // ---- Large HR ----
        var hrStr = orchestrator.sensor.currentHr > 0
            ? orchestrator.sensor.currentHr.toString()
            : "--";
        dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, 60, Graphics.FONT_NUMBER_THAI_HOT, hrStr, Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, 145, Graphics.FONT_TINY, "bpm", Graphics.TEXT_JUSTIFY_CENTER);

        // ---- DFA α1 row ----
        var dfa    = orchestrator.latestDfa;
        var dfaStr = dfa > 0.0f ? dfa.format("%.2f") : "---";
        var windowLabel = orchestrator.isInAnalysisWindow() ? "✓ Analysis" : "↷ Settling";
        var windowColour = orchestrator.isInAnalysisWindow() ? Graphics.COLOR_GREEN : Graphics.COLOR_YELLOW;

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(18, 168, Graphics.FONT_TINY, "DFA α1", Graphics.TEXT_JUSTIFY_LEFT);
        dc.setColor(_dfaColour(dfa), Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx - 10, 168, Graphics.FONT_SMALL, dfaStr, Graphics.TEXT_JUSTIFY_LEFT);
        dc.setColor(windowColour, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w - 18, 168, Graphics.FONT_TINY, windowLabel, Graphics.TEXT_JUSTIFY_RIGHT);

        // ---- Stage guidance row (Phase 2) ----
        var targetLine = orchestrator.currentStageTargetLine();
        if (targetLine.length() > 0) {
            dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, 200, Graphics.FONT_TINY, targetLine, Graphics.TEXT_JUSTIFY_CENTER);
        }

        // ---- Live LT1 estimate row ----
        _drawLT1Row(dc, w, cx, 228);

        _drawDivider(dc, w, 258);

        // ---- Bottom: RR quality + source ----
        _drawQualityBar(dc, w, cx, 270);

        // ---- Paused overlay ----
        if (orchestrator.state == STATE_PAUSED) {
            dc.setColor(Graphics.COLOR_ORANGE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, h - 50, Graphics.FONT_MEDIUM, "PAUSED", Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    // =========================================================================
    // TRANSITION screen
    // =========================================================================
    private function _drawTransition(dc as Graphics.Dc, w as Number, h as Number, cx as Number) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, 50, Graphics.FONT_MEDIUM, "Rest", Graphics.TEXT_JUSTIFY_CENTER);

        var remaining = orchestrator.timeRemainingInStage();
        dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, 100, Graphics.FONT_NUMBER_THAI_HOT, remaining.toString(), Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, 190, Graphics.FONT_TINY, "seconds", Graphics.TEXT_JUSTIFY_CENTER);

        _drawDivider(dc, w, 220);

        // Next stage target guidance — the key Phase 2 feature during transition.
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, 235, Graphics.FONT_TINY, "Next stage target:", Graphics.TEXT_JUSTIFY_CENTER);
        var nextTarget = orchestrator.nextStageTargetLine();
        dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, 260, Graphics.FONT_TINY, nextTarget, Graphics.TEXT_JUSTIFY_CENTER);

        // Live HR during rest.
        var hrStr = orchestrator.sensor.currentHr > 0
            ? orchestrator.sensor.currentHr.toString() + " bpm"
            : "--- bpm";
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, 315, Graphics.FONT_SMALL, hrStr, Graphics.TEXT_JUSTIFY_CENTER);
    }

    // =========================================================================
    // COMPLETE screen
    // =========================================================================
    private function _drawComplete(dc as Graphics.Dc, w as Number, h as Number, cx as Number) as Void {
        var result = orchestrator.finalResult;

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, 30, Graphics.FONT_SMALL, "Test Complete", Graphics.TEXT_JUSTIFY_CENTER);
        _drawDivider(dc, w, 60);

        if (result == null) {
            dc.drawText(cx, h / 2, Graphics.FONT_SMALL, "Processing...", Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        if (result.isDetected()) {
            // LT1 HR — large, centred.
            dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, 75, Graphics.FONT_TINY, "LT1 Detected", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, 100, Graphics.FONT_NUMBER_THAI_HOT,
                result.lt1Hr.format("%.0f"), Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, 185, Graphics.FONT_TINY, "bpm", Graphics.TEXT_JUSTIFY_CENTER);

            // Pace (if available).
            if (result.lt1Pace > 0.0f) {
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.drawText(cx, 210, Graphics.FONT_SMALL,
                    _paceSmToMinKm(result.lt1Pace) + " /km", Graphics.TEXT_JUSTIFY_CENTER);
            }

            // Power (if available).
            if (result.lt1Power > 0.0f) {
                dc.drawText(cx, 240, Graphics.FONT_SMALL,
                    result.lt1Power.format("%.0f") + " W", Graphics.TEXT_JUSTIFY_CENTER);
            }

            // Confidence.
            var confColour = result.confidenceScore >= 0.75f ? Graphics.COLOR_GREEN :
                             result.confidenceScore >= 0.45f ? Graphics.COLOR_YELLOW :
                                                               Graphics.COLOR_RED;
            dc.setColor(confColour, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, 280, Graphics.FONT_SMALL,
                "Confidence: " + result.confidenceLabel(), Graphics.TEXT_JUSTIFY_CENTER);

        } else {
            dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, 140, Graphics.FONT_MEDIUM, "Not detected", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, 200, Graphics.FONT_TINY, "Check signal quality", Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(cx, 225, Graphics.FONT_TINY, "or repeat test", Graphics.TEXT_JUSTIFY_CENTER);
        }

        _drawDivider(dc, w, 320);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, 335, Graphics.FONT_TINY,
            "RR qual: " + (result.signalQualityOverall * 100.0f).format("%.0f") + "%",
            Graphics.TEXT_JUSTIFY_CENTER);

        var srcLabel = result.hrSourceIsChestStrap ? "Chest strap" : "Optical ⚠";
        dc.setColor(result.hrSourceIsChestStrap ? Graphics.COLOR_GREEN : Graphics.COLOR_YELLOW,
                    Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, 358, Graphics.FONT_TINY, srcLabel, Graphics.TEXT_JUSTIFY_CENTER);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h - 28, Graphics.FONT_TINY, "START to exit", Graphics.TEXT_JUSTIFY_CENTER);
    }

    // =========================================================================
    // Shared sub-renderers
    // =========================================================================

    private function _drawLT1Row(dc as Graphics.Dc, w as Number, cx as Number, y as Number) as Void {
        var result = orchestrator.finalResult;
        // Show provisional detection from LT1Detector if stages are completing.
        // (finalResult is only set at STATE_COMPLETE; during the test we show
        //  nothing for this row until detection is available via lt1Detector.)
        // For the MVP we simply show dashes during the test.
        // TODO Phase 3: run provisional detect() after each stage and display.
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(18, y, Graphics.FONT_TINY, "LT1", Graphics.TEXT_JUSTIFY_LEFT);
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y, Graphics.FONT_TINY, "—", Graphics.TEXT_JUSTIFY_CENTER);
    }

    private function _drawQualityBar(dc as Graphics.Dc, w as Number, cx as Number, y as Number) as Void {
        var qualPct   = (orchestrator.sensor.rrQuality * 100.0f).toNumber();
        var isStrap   = orchestrator.sensor.isChestStrap;
        var srcLabel  = isStrap ? "CHEST STRAP" : "OPTICAL ⚠";
        var srcColour = isStrap ? Graphics.COLOR_GREEN : Graphics.COLOR_YELLOW;

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(18, y, Graphics.FONT_TINY, "RR " + qualPct + "%", Graphics.TEXT_JUSTIFY_LEFT);
        dc.setColor(srcColour, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w - 18, y, Graphics.FONT_TINY, srcLabel, Graphics.TEXT_JUSTIFY_RIGHT);
    }

    private function _drawDivider(dc as Graphics.Dc, w as Number, y as Number) as Void {
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(30, y, w - 30, y);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    private function _formatMMSS(totalSecs as Number) as String {
        var mins = totalSecs / 60;
        var secs = totalSecs % 60;
        return Lang.format("$1$:$2$",
            [mins.toString(), secs < 10 ? "0" + secs : secs.toString()]);
    }

    // Convert pace in s/m to "M:SS" /km string.
    private function _paceSmToMinKm(paceSmPerMeter as Float) as String {
        var totalSecsPerKm = (paceSmPerMeter * 1000.0f).toNumber();
        var mins = totalSecsPerKm / 60;
        var secs = totalSecsPerKm % 60;
        return Lang.format("$1$:$2$",
            [mins.toString(), secs < 10 ? "0" + secs : secs.toString()]);
    }

    private function _dfaColour(dfa as Float) as Number {
        if (dfa < 0.0f)   { return Graphics.COLOR_LT_GRAY; }
        if (dfa >= 0.80f) { return Graphics.COLOR_GREEN; }
        if (dfa >= 0.70f) { return Graphics.COLOR_YELLOW; }
        return Graphics.COLOR_RED;
    }
}
