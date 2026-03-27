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

    private const SAFE_LEFT = 42;
    private const SAFE_RIGHT = 42;
    private const SAFE_TOP = 34;
    private const SAFE_BOTTOM = 26;
    private const ROW_HALF_SPAN = 54;

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
        var titleY = SAFE_TOP + 6;
        var statusY = titleY + 44;
        var hintY = statusY + 24;
        var metaY = hintY + 28;
        var footerY = h - SAFE_BOTTOM - 40;

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, titleY, Graphics.FONT_MEDIUM, "LT1 Test", Graphics.TEXT_JUSTIFY_CENTER);

        var isStrap   = orchestrator.sensor.isChestStrap;
        var srcLabel  = isStrap ? "Chest Strap" : "Optical HR";
        var srcColour = isStrap ? Graphics.COLOR_GREEN : Graphics.COLOR_YELLOW;
        dc.setColor(srcColour, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, statusY, Graphics.FONT_SMALL, srcLabel, Graphics.TEXT_JUSTIFY_CENTER);

        if (!isStrap) {
            dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, hintY, Graphics.FONT_XTINY, "Best with chest strap", Graphics.TEXT_JUSTIFY_CENTER);
        } else {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, hintY, Graphics.FONT_XTINY, "RR stream ready", Graphics.TEXT_JUSTIFY_CENTER);
        }

        var hrMax = orchestrator.stageGuide.getHRMax();
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, metaY, Graphics.FONT_XTINY, "HRmax " + hrMax + " bpm", Graphics.TEXT_JUSTIFY_CENTER);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, footerY, Graphics.FONT_SMALL, "START to begin", Graphics.TEXT_JUSTIFY_CENTER);
    }

    // =========================================================================
    // RUNNING layout (Warmup / Stage / Paused)
    // =========================================================================
    private function _drawRunningLayout(dc as Graphics.Dc, w as Number, h as Number, cx as Number) as Void {
        var stateStr = _compactStateLabel();
        var timeStr  = _formatMMSS(orchestrator.timeRemainingInStage());
        var topStateY = SAFE_TOP - 2;
        var topTimeY = topStateY + 14;
        var dividerY = topTimeY + 16;
        var hrY = dividerY + 8;
        var bpmY = hrY + 62;
        var dfaRowY = bpmY + 24;
        var sigRowY = dfaRowY + 22;
        var targetY = sigRowY + 24;
        var footerY = h - SAFE_BOTTOM - 12;

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, topStateY, Graphics.FONT_XTINY, stateStr, Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, topTimeY, Graphics.FONT_XTINY, timeStr, Graphics.TEXT_JUSTIFY_CENTER);
        _drawDivider(dc, w, dividerY);

        var hrStr = orchestrator.sensor.currentHr > 0
            ? orchestrator.sensor.currentHr.toString()
            : "--";
        dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, hrY, Graphics.FONT_NUMBER_HOT, hrStr, Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, bpmY, Graphics.FONT_XTINY, "bpm", Graphics.TEXT_JUSTIFY_CENTER);

        var dfa    = orchestrator.latestDfa;
        var dfaStr = dfa > 0.0f ? dfa.format("%.2f") : "---";
        var windowLabel = orchestrator.isInAnalysisWindow() ? "LIVE" : "WAIT";
        var windowColour = orchestrator.isInAnalysisWindow() ? Graphics.COLOR_GREEN : Graphics.COLOR_YELLOW;
        var qualPct = (orchestrator.sensor.rrQuality * 100.0f).toNumber();
        var srcLabel = orchestrator.sensor.isChestStrap ? "CHEST" : "OPT";
        var srcColour = orchestrator.sensor.isChestStrap ? Graphics.COLOR_GREEN : Graphics.COLOR_YELLOW;
        var leftColX = cx - ROW_HALF_SPAN;
        var rightColX = cx + ROW_HALF_SPAN;

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(leftColX, dfaRowY, Graphics.FONT_XTINY, "DFA", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(_dfaColour(dfa), Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, dfaRowY - 2, Graphics.FONT_TINY, dfaStr, Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(windowColour, Graphics.COLOR_TRANSPARENT);
        dc.drawText(rightColX, dfaRowY, Graphics.FONT_XTINY, windowLabel, Graphics.TEXT_JUSTIFY_CENTER);

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(leftColX, sigRowY, Graphics.FONT_XTINY, "SIG " + qualPct + "%", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(srcColour, Graphics.COLOR_TRANSPARENT);
        dc.drawText(rightColX, sigRowY, Graphics.FONT_XTINY, srcLabel, Graphics.TEXT_JUSTIFY_CENTER);

        var targetLine = orchestrator.state == STATE_STAGE ? orchestrator.currentStageTargetLine() : "";
        if (targetLine.length() > 0) {
            dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
            _drawWrappedLine(dc, cx, targetY, targetLine);
        }

        if (orchestrator.state == STATE_STAGE) {
            _drawLT1Row(dc, w, cx, footerY - 12);
        }

        if (orchestrator.state == STATE_PAUSED) {
            dc.setColor(Graphics.COLOR_ORANGE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, footerY, Graphics.FONT_SMALL, "PAUSED", Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    // =========================================================================
    // TRANSITION screen
    // =========================================================================
    private function _drawTransition(dc as Graphics.Dc, w as Number, h as Number, cx as Number) as Void {
        var titleY = SAFE_TOP - 2;
        var countY = titleY + 26;
        var unitY = countY + 58;
        var dividerY = unitY + 18;
        var nextLabelY = dividerY + 14;
        var targetY = nextLabelY + 16;
        var hrY = targetY + 40;

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, titleY, Graphics.FONT_SMALL, "Rest", Graphics.TEXT_JUSTIFY_CENTER);

        var remaining = orchestrator.timeRemainingInStage();
        dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, countY, Graphics.FONT_NUMBER_HOT, remaining.toString(), Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, unitY, Graphics.FONT_XTINY, "sec", Graphics.TEXT_JUSTIFY_CENTER);

        _drawDivider(dc, w, dividerY);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, nextLabelY, Graphics.FONT_XTINY, "Next Stage", Graphics.TEXT_JUSTIFY_CENTER);
        var nextTarget = orchestrator.nextStageTargetLine();
        dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
        _drawWrappedLine(dc, cx, targetY, nextTarget);

        var hrStr = orchestrator.sensor.currentHr > 0
            ? orchestrator.sensor.currentHr.toString() + " bpm"
            : "--- bpm";
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, hrY, Graphics.FONT_XTINY, hrStr, Graphics.TEXT_JUSTIFY_CENTER);
    }

    // =========================================================================
    // COMPLETE screen
    // =========================================================================
    private function _drawComplete(dc as Graphics.Dc, w as Number, h as Number, cx as Number) as Void {
        var result = orchestrator.finalResult;
        var titleY = SAFE_TOP - 2;
        var dividerY = titleY + 30;

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, titleY, Graphics.FONT_SMALL, "Test Complete", Graphics.TEXT_JUSTIFY_CENTER);
        _drawDivider(dc, w, dividerY);

        if (result == null) {
            dc.drawText(cx, h / 2, Graphics.FONT_SMALL, "Processing...", Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        if (result.isDetected()) {
            dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, dividerY + 14, Graphics.FONT_TINY, "LT1 Found", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, dividerY + 38, Graphics.FONT_NUMBER_THAI_HOT,
                result.lt1Hr.format("%.0f"), Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, dividerY + 122, Graphics.FONT_TINY, "bpm", Graphics.TEXT_JUSTIFY_CENTER);

            if (result.lt1Pace > 0.0f) {
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.drawText(cx, dividerY + 144, Graphics.FONT_SMALL,
                    _paceSmToMinKm(result.lt1Pace) + " /km", Graphics.TEXT_JUSTIFY_CENTER);
            }

            if (result.lt1Power > 0.0f) {
                dc.drawText(cx, dividerY + 170, Graphics.FONT_SMALL,
                    result.lt1Power.format("%.0f") + " W", Graphics.TEXT_JUSTIFY_CENTER);
            }

            var confColour = result.confidenceScore >= 0.75f ? Graphics.COLOR_GREEN :
                             result.confidenceScore >= 0.45f ? Graphics.COLOR_YELLOW :
                                                               Graphics.COLOR_RED;
            dc.setColor(confColour, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, dividerY + 198, Graphics.FONT_XTINY,
                "Confidence " + result.confidenceLabel(), Graphics.TEXT_JUSTIFY_CENTER);

        } else {
            dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, dividerY + 70, Graphics.FONT_MEDIUM, "No LT1 Yet", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, dividerY + 112, Graphics.FONT_XTINY, "Signal too weak", Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(cx, dividerY + 128, Graphics.FONT_XTINY, "Retry with chest strap", Graphics.TEXT_JUSTIFY_CENTER);

            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, h - SAFE_BOTTOM - 10, Graphics.FONT_XTINY, "START to exit", Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        _drawDivider(dc, w, h - SAFE_BOTTOM - 58);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h - SAFE_BOTTOM - 48, Graphics.FONT_XTINY,
            "Signal " + (result.signalQualityOverall * 100.0f).format("%.0f") + "%",
            Graphics.TEXT_JUSTIFY_CENTER);

        var srcLabel = result.hrSourceIsChestStrap ? "Chest strap" : "Optical HR";
        dc.setColor(result.hrSourceIsChestStrap ? Graphics.COLOR_GREEN : Graphics.COLOR_YELLOW,
                    Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h - SAFE_BOTTOM - 30, Graphics.FONT_XTINY, srcLabel, Graphics.TEXT_JUSTIFY_CENTER);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h - SAFE_BOTTOM - 10, Graphics.FONT_XTINY, "START to exit", Graphics.TEXT_JUSTIFY_CENTER);
    }

    // =========================================================================
    // Shared sub-renderers
    // =========================================================================

    private function _drawLT1Row(dc as Graphics.Dc, w as Number, cx as Number, y as Number) as Void {
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx - ROW_HALF_SPAN, y, Graphics.FONT_XTINY, "LT1", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx + 6, y, Graphics.FONT_XTINY, "--", Graphics.TEXT_JUSTIFY_CENTER);
    }

    private function _drawDivider(dc as Graphics.Dc, w as Number, y as Number) as Void {
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(SAFE_LEFT, y, w - SAFE_RIGHT, y);
    }

    private function _drawWrappedLine(dc as Graphics.Dc, cx as Number, y as Number, line as String) as Void {
        if (line.length() <= 16) {
            dc.drawText(cx, y, Graphics.FONT_XTINY, line, Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        var split = -1;
        var half = line.length() / 2;
        for (var i = half; i < line.length(); i++) {
            if (line.substring(i, 1) == " ") {
                split = i;
                break;
            }
        }

        if (split <= 0) {
            dc.drawText(cx, y, Graphics.FONT_XTINY, line, Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        var top = line.substring(0, split);
        // substring(start, length) — guard against empty remainder
        var remainingLen = line.length() - (split + 1);
        if (remainingLen <= 0) {
            dc.drawText(cx, y, Graphics.FONT_XTINY, line, Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }
        var bottom = line.substring(split + 1, remainingLen);
        dc.drawText(cx, y, Graphics.FONT_XTINY, top, Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(cx, y + 11, Graphics.FONT_XTINY, bottom, Graphics.TEXT_JUSTIFY_CENTER);
    }

    private function _compactStateLabel() as String {
        switch (orchestrator.state) {
            case STATE_WARMUP: return "WU";
            case STATE_STAGE: return "S" + orchestrator.currentStage;
            case STATE_TRANSITION: return "REST";
            case STATE_PAUSED: return "PAUSE";
            case STATE_COMPLETE: return "DONE";
            default: return orchestrator.stateLabel();
        }
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
