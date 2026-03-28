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
        var isRect = _isRectScreen(w, h);

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        // Route to specialised layouts for IDLE / COMPLETE / TRANSITION.
        var state = orchestrator.state;
        if (state == STATE_IDLE)       { if (isRect) { _drawIdleRect(dc, w, h, cx); } else { _drawIdle(dc, w, h, cx); } return; }
        if (state == STATE_COMPLETE)   { if (isRect) { _drawCompleteRect(dc, w, h, cx); } else { _drawComplete(dc, w, h, cx); } return; }
        if (state == STATE_TRANSITION) { if (isRect) { _drawTransitionRect(dc, w, h, cx); } else { _drawTransition(dc, w, h, cx); } return; }

        // ---- WARMUP / STAGE / PAUSED layout ----
        if (isRect) {
            _drawRunningLayoutRect(dc, w, h, cx);
        } else {
            _drawRunningLayout(dc, w, h, cx);
        }
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

    private function _drawIdleRect(dc as Graphics.Dc, w as Number, h as Number, cx as Number) as Void {
        var margin = _rectMargin(w);
        var compact = _isCompactRect(w, h);
        var large = _isLargeRect(w, h);
        var titleFont = large ? Graphics.FONT_LARGE : Graphics.FONT_MEDIUM;
        var statusFont = compact ? Graphics.FONT_XTINY : Graphics.FONT_SMALL;
        var titleY = compact ? 10 : 12;
        var statusY = compact ? 38 : 46;
        var hintY = statusY + (compact ? 18 : 22);
        var detailY = hintY + (compact ? 14 : 18);
        var footerY = h - (compact ? 18 : 28);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, titleY, titleFont, compact ? "LT1 Test" : "LT1 Step Test", Graphics.TEXT_JUSTIFY_CENTER);

        var isStrap = orchestrator.sensor.isChestStrap;
        var srcLabel = isStrap
            ? (compact ? "Chest strap ready" : "Chest Strap Connected")
            : (compact ? "Optical fallback" : "Optical HR Fallback");
        dc.setColor(isStrap ? Graphics.COLOR_GREEN : Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, statusY, statusFont, srcLabel, Graphics.TEXT_JUSTIFY_CENTER);

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, hintY, Graphics.FONT_XTINY,
            compact ? "Warmup + guided stages" : "Guided warmup plus staged LT1 test",
            Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(cx, detailY, Graphics.FONT_XTINY,
            compact ? "Best with chest strap" : "Best accuracy: pair chest strap before start",
            Graphics.TEXT_JUSTIFY_CENTER);

        _drawRectDivider(dc, w, detailY + (compact ? 16 : 20), margin);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, footerY, compact ? Graphics.FONT_XTINY : Graphics.FONT_SMALL,
            compact ? "Enter/Start to begin" : "Press Enter/Start to begin",
            Graphics.TEXT_JUSTIFY_CENTER);
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

    private function _drawRunningLayoutRect(dc as Graphics.Dc, w as Number, h as Number, cx as Number) as Void {
        var margin = _rectMargin(w);
        var compact = _isCompactRect(w, h);
        var large = _isLargeRect(w, h);
        var topY = compact ? 8 : 10;
        var divider1Y = compact ? 24 : 30;
        var hrY = compact ? 34 : (large ? 52 : 42);
        var bpmY = hrY + (compact ? 34 : 42);
        var rowGap = compact ? 15 : 18;
        var row1Y = bpmY + (compact ? 14 : 18);
        var row2Y = row1Y + rowGap;
        var row3Y = row2Y + rowGap;
        var targetY = row3Y + (compact ? 20 : 26);
        var footerY = h - (compact ? 10 : 18);
        var headerFont = compact ? Graphics.FONT_XTINY : Graphics.FONT_TINY;
        var valueFont = compact ? Graphics.FONT_TINY : Graphics.FONT_XTINY;
        var footerFont = compact ? Graphics.FONT_XTINY : Graphics.FONT_TINY;
        var timeStr = _formatMMSS(orchestrator.timeRemainingInStage());
        var dfa = orchestrator.latestDfa;
        var dfaStr = dfa > 0.0f ? dfa.format("%.2f") : "---";
        var qualPct = (orchestrator.sensor.rrQuality * 100.0f).toNumber();
        var sourceLabel = orchestrator.sensor.isChestStrap ? "CHEST" : "OPT";
        var srcColour = orchestrator.sensor.isChestStrap ? Graphics.COLOR_GREEN : Graphics.COLOR_YELLOW;
        var windowLabel = orchestrator.isInAnalysisWindow() ? "LIVE" : "WAIT";
        var windowColour = orchestrator.isInAnalysisWindow() ? Graphics.COLOR_GREEN : Graphics.COLOR_YELLOW;

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(margin, topY, headerFont, _expandedStateLabel(), Graphics.TEXT_JUSTIFY_LEFT);
        dc.drawText(w - margin, topY, headerFont, timeStr, Graphics.TEXT_JUSTIFY_RIGHT);
        _drawRectDivider(dc, w, divider1Y, margin);

        var hrStr = orchestrator.sensor.currentHr > 0 ? orchestrator.sensor.currentHr.toString() : "--";
        dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, hrY, Graphics.FONT_NUMBER_HOT, hrStr, Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, bpmY, Graphics.FONT_XTINY, "bpm", Graphics.TEXT_JUSTIFY_CENTER);

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(margin, row1Y, headerFont, "DFA", Graphics.TEXT_JUSTIFY_LEFT);
        dc.setColor(_dfaColour(dfa), Graphics.COLOR_TRANSPARENT);
        dc.drawText(margin + (compact ? 30 : 38), row1Y, valueFont, dfaStr, Graphics.TEXT_JUSTIFY_LEFT);
        dc.setColor(windowColour, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w - margin, row1Y, headerFont, windowLabel, Graphics.TEXT_JUSTIFY_RIGHT);

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(margin, row2Y, headerFont,
            compact ? ("Sig " + qualPct + "%") : ("Signal " + qualPct + "%"),
            Graphics.TEXT_JUSTIFY_LEFT);
        dc.setColor(srcColour, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w - margin, row2Y, headerFont, sourceLabel, Graphics.TEXT_JUSTIFY_RIGHT);

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(margin, row3Y, headerFont,
            orchestrator.state == STATE_STAGE ? "Stage " + orchestrator.currentStage : "Guided step test",
            Graphics.TEXT_JUSTIFY_LEFT);
        if (orchestrator.state == STATE_STAGE) {
            dc.drawText(w - margin, row3Y, headerFont, "LT1 --", Graphics.TEXT_JUSTIFY_RIGHT);
        } else if (orchestrator.state == STATE_PAUSED) {
            dc.setColor(Graphics.COLOR_ORANGE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w - margin, row3Y, headerFont, "PAUSED", Graphics.TEXT_JUSTIFY_RIGHT);
        }

        var targetLine = orchestrator.state == STATE_STAGE ? orchestrator.currentStageTargetLine() : "";
        if (targetLine.length() > 0) {
            _drawRectDivider(dc, w, targetY - 10, margin);
            dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
            _drawWrappedRectLine(dc, w, margin, targetY, targetLine);
        } else if (orchestrator.state == STATE_WARMUP) {
            _drawRectDivider(dc, w, targetY - 10, margin);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, targetY, headerFont,
                compact ? "Warmup: settle HR + RR" : "Warmup: settle HR and RR signal",
                Graphics.TEXT_JUSTIFY_CENTER);
        }

        if (orchestrator.state == STATE_STAGE) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, footerY, footerFont,
                compact ? "Lap skip  |  Back save" : "Lap skips stage  |  Back saves test",
                Graphics.TEXT_JUSTIFY_CENTER);
        } else if (orchestrator.state == STATE_PAUSED) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, footerY, footerFont,
                compact ? "Enter/Start to resume" : "Press Enter/Start to resume",
                Graphics.TEXT_JUSTIFY_CENTER);
        } else {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, footerY, footerFont,
                compact ? "Back saves test" : "Back saves current test",
                Graphics.TEXT_JUSTIFY_CENTER);
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

    private function _drawTransitionRect(dc as Graphics.Dc, w as Number, h as Number, cx as Number) as Void {
        var margin = _rectMargin(w);
        var compact = _isCompactRect(w, h);
        var titleY = compact ? 10 : 12;
        var countY = compact ? 30 : 36;
        var dividerY = compact ? 74 : 88;
        var targetY = dividerY + (compact ? 14 : 18);
        var footerY = h - (compact ? 10 : 18);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, titleY, compact ? Graphics.FONT_SMALL : Graphics.FONT_MEDIUM, "Recovery", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, countY, Graphics.FONT_NUMBER_HOT, orchestrator.timeRemainingInStage().toString(), Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, countY + (compact ? 38 : 44), Graphics.FONT_XTINY,
            compact ? "sec" : "seconds", Graphics.TEXT_JUSTIFY_CENTER);

        _drawRectDivider(dc, w, dividerY, margin);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, targetY, Graphics.FONT_XTINY,
            compact ? "Next target" : "Next Stage Target", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
        _drawWrappedRectLine(dc, w, margin, targetY + 18, orchestrator.nextStageTargetLine());

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, footerY, Graphics.FONT_XTINY,
            compact ? "Prepare intensity change" : "Prepare for the next intensity change",
            Graphics.TEXT_JUSTIFY_CENTER);
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

    private function _drawCompleteRect(dc as Graphics.Dc, w as Number, h as Number, cx as Number) as Void {
        var result = orchestrator.finalResult;
        var margin = _rectMargin(w);
        var compact = _isCompactRect(w, h);
        var large = _isLargeRect(w, h);
        var titleY = compact ? 8 : 10;
        var dividerY = compact ? 28 : 34;

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, titleY, large ? Graphics.FONT_LARGE : Graphics.FONT_MEDIUM, "Test Complete", Graphics.TEXT_JUSTIFY_CENTER);
        _drawRectDivider(dc, w, dividerY, margin);

        if (result == null) {
            dc.drawText(cx, h / 2, Graphics.FONT_SMALL, "Processing...", Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        if (result.isDetected()) {
            dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, dividerY + (compact ? 8 : 10), compact ? Graphics.FONT_TINY : Graphics.FONT_SMALL, "LT1 Found", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, dividerY + (compact ? 28 : 34), Graphics.FONT_NUMBER_HOT, result.lt1Hr.format("%.0f"), Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, dividerY + (compact ? 72 : 80), Graphics.FONT_XTINY, "bpm", Graphics.TEXT_JUSTIFY_CENTER);

            var rowY = dividerY + (compact ? 92 : 104);
            if (result.lt1Pace > 0.0f) {
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.drawText(cx, rowY, compact ? Graphics.FONT_TINY : Graphics.FONT_SMALL, _paceSmToMinKm(result.lt1Pace) + " /km", Graphics.TEXT_JUSTIFY_CENTER);
                rowY += compact ? 18 : 22;
            }
            if (result.lt1Power > 0.0f) {
                dc.drawText(cx, rowY, compact ? Graphics.FONT_TINY : Graphics.FONT_SMALL, result.lt1Power.format("%.0f") + " W", Graphics.TEXT_JUSTIFY_CENTER);
                rowY += compact ? 18 : 22;
            }

            var confColour = result.confidenceScore >= 0.75f ? Graphics.COLOR_GREEN :
                             result.confidenceScore >= 0.45f ? Graphics.COLOR_YELLOW :
                                                               Graphics.COLOR_RED;
            dc.setColor(confColour, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, rowY, Graphics.FONT_XTINY, "Confidence " + result.confidenceLabel(), Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, h - (compact ? 30 : 42), Graphics.FONT_XTINY,
                "Signal " + (result.signalQualityOverall * 100.0f).format("%.0f") + "%",
                Graphics.TEXT_JUSTIFY_CENTER);
        } else {
            dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, dividerY + (compact ? 36 : 44), compact ? Graphics.FONT_SMALL : Graphics.FONT_MEDIUM, "No LT1 Yet", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, dividerY + (compact ? 62 : 76), Graphics.FONT_XTINY,
                compact ? "Signal too weak" : "Signal too weak for reliable detection",
                Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(cx, dividerY + (compact ? 78 : 94), Graphics.FONT_XTINY,
                compact ? "Retry with chest strap" : "Retry with a chest strap if possible",
                Graphics.TEXT_JUSTIFY_CENTER);
        }

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h - (compact ? 10 : 18), Graphics.FONT_XTINY,
            compact ? "Enter/Start to exit" : "Press Enter/Start to exit",
            Graphics.TEXT_JUSTIFY_CENTER);
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

    private function _drawRectDivider(dc as Graphics.Dc, w as Number, y as Number, margin as Number) as Void {
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(margin, y, w - margin, y);
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

    private function _drawWrappedRectLine(dc as Graphics.Dc, w as Number, margin as Number, y as Number, line as String) as Void {
        if (line.length() <= 28) {
            dc.drawText(w / 2, y, Graphics.FONT_XTINY, line, Graphics.TEXT_JUSTIFY_CENTER);
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
            dc.drawText(w / 2, y, Graphics.FONT_XTINY, line, Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        var top = line.substring(0, split);
        var remainingLen = line.length() - (split + 1);
        if (remainingLen <= 0) {
            dc.drawText(w / 2, y, Graphics.FONT_XTINY, line, Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }
        var bottom = line.substring(split + 1, remainingLen);
        dc.drawText(w / 2, y, Graphics.FONT_XTINY, top, Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(w / 2, y + 13, Graphics.FONT_XTINY, bottom, Graphics.TEXT_JUSTIFY_CENTER);
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

    private function _expandedStateLabel() as String {
        switch (orchestrator.state) {
            case STATE_WARMUP: return "Warmup";
            case STATE_STAGE: return "Stage " + orchestrator.currentStage;
            case STATE_TRANSITION: return "Recovery";
            case STATE_PAUSED: return "Paused";
            case STATE_COMPLETE: return "Complete";
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

    private function _isRectScreen(w as Number, h as Number) as Boolean {
        return (w > h + 20) || (h > w + 20);
    }

    private function _rectMargin(w as Number) as Number {
        return w >= 320 ? 18 : 10;
    }

    private function _isCompactRect(w as Number, h as Number) as Boolean {
        return w <= 280 || h <= 320;
    }

    private function _isLargeRect(w as Number, h as Number) as Boolean {
        return w >= 400 || h >= 600;
    }
}
