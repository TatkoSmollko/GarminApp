// UploadManager.mc
// Accumulates HR/pace/DFA timeseries during the test and POSTs the full
// payload to the backend after the test completes.
//
// ── Payload structure (JSON, ~30-40 KB with raw RR; ~8 KB without) ──────────
// {
//   "v":          1,                    // schema version
//   "email":      "user@example.com",
//   "test_date":  "2024-06-15",
//   "duration_s": 2190,
//   "hr_source":  "strap",             // "strap" | "optical"
//   "lt1": {
//     "hr":       152.3,
//     "pace_sm":  0.292,
//     "power_w":  0.0,
//     "conf":     0.82,
//     "stage":    5,
//     "sig_qual": 0.88
//   },
//   "stages": [
//     { "n":1, "hr":125.1, "pace_sm":0.330, "dfa":1.04, "val":0.95 },
//     ...
//   ],
//   "ts": {
//     "hr_interval_s":  1,             // HR/pace sampled every 1 s (full trace)
//     "hr":   [120, 122, ...],         // integers, bpm (up to 2500 samples)
//     "pace": [330, 329, ...],         // integers, seconds per km (rounded)
//     "dfa_interval_s": 30,            // watch-side DFA sampled every 30 s (fallback)
//     "dfa":   [104, 101, 95, ...],    // float ×100 stored as integer (e.g. 104 = 1.04)
//     "stage": [0, 0, 1, 1, ...],
//     "qual":  [85, 88, 92, ...],      // 0-100
//     "rr_ms": [812, 798, 820, ...]    // raw per-beat RR intervals in ms (up to 5500)
//   }
// }
//
// ── Retry logic ──────────────────────────────────────────────────────────────
// If the POST fails (no BT/WiFi at test end), the payload is saved to
// AppStorage under key "lt1_pending_upload".
// attemptPendingUpload() is called from LT1TestApp.onStart() so the upload
// is retried every time the app is opened until it succeeds.

import Toybox.Lang;
import Toybox.Communications;
import Toybox.Application;
import Toybox.Time;
import Toybox.System;

class UploadManager {

    // ── Timeseries buffers ────────────────────────────────────────────────────
    // Pre-allocated to avoid GC churn during the test.
    // Max capacity: 2500 HR samples (1 s interval, ~41 min test)
    //               80 DFA samples (30 s interval, watch-side)
    //               5500 RR intervals (~37.5 min at avg 150 bpm with headroom)

    private const MAX_HR_SAMPLES  = 2500;
    private const MAX_DFA_SAMPLES = 80;
    private const MAX_RR_SAMPLES  = 5500;
    private const HR_SAMPLE_EVERY = 1;   // seconds — every second for full trace

    private var hrBuf    as Array;    // integer bpm
    private var paceBuf  as Array;    // integer s/km (rounded)
    private var dfaBuf   as Array;    // integer dfa×100 (e.g. 95 = 0.95)
    private var stageBuf as Array;    // integer stage number
    private var qualBuf  as Array;    // integer 0-100
    private var rrBuf    as Array;    // integer RR intervals in ms (raw per-beat)

    private var hrCount  as Number;
    private var dfaCount as Number;
    private var rrCount  as Number;

    // Counts seconds between HR samples.
    private var hrSampleTick as Number;

    // AppStorage keys
    private const KEY_PENDING = "lt1_pending_upload";

    function initialize() {
        hrBuf    = new [MAX_HR_SAMPLES];
        paceBuf  = new [MAX_HR_SAMPLES];
        dfaBuf   = new [MAX_DFA_SAMPLES];
        stageBuf = new [MAX_DFA_SAMPLES];
        qualBuf  = new [MAX_DFA_SAMPLES];
        rrBuf    = new [MAX_RR_SAMPLES];
        hrCount = 0;
        dfaCount = 0;
        rrCount = 0;
        hrSampleTick = 0;
        _reset();
    }

    // ── Called at test start ──────────────────────────────────────────────────
    function reset() as Void {
        _reset();
    }

    // ── Called for every real RR interval from SensorLayer ───────────────────
    function onRRInterval(rr as Number) as Void {
        if (rrCount >= MAX_RR_SAMPLES) { return; }   // buffer full — drop
        rrBuf[rrCount] = rr;
        rrCount++;
    }

    // ── Called every second from TestOrchestrator.onSecondTick() ─────────────
    function onSecondTick(hr as Number, paceSmFloat as Float) as Void {
        hrSampleTick++;
        if (hrSampleTick < HR_SAMPLE_EVERY) { return; }
        hrSampleTick = 0;

        if (hrCount >= MAX_HR_SAMPLES) { return; }   // buffer full — drop

        hrBuf[hrCount]   = hr;
        // Convert pace s/m → s/km (integer, rounded) for compact JSON.
        // e.g. 0.330 s/m × 1000 = 330 s/km = 5:30/km
        paceBuf[hrCount] = paceSmFloat > 0.0f
            ? (paceSmFloat * 1000.0f + 0.5f).toNumber()
            : 0;
        hrCount++;
    }

    // ── Called every DFA tick from TestOrchestrator.onDFATick() ──────────────
    function onDFATick(dfa as Float, stage as Number, qualFraction as Float) as Void {
        if (dfaCount >= MAX_DFA_SAMPLES) { return; }

        // Store DFA as integer ×100 to avoid float precision issues in JSON.
        // e.g. 0.95 → 95, 1.04 → 104
        dfaBuf[dfaCount]   = dfa > 0.0f ? (dfa * 100.0f + 0.5f).toNumber() : -1;
        stageBuf[dfaCount] = stage;
        qualBuf[dfaCount]  = (qualFraction * 100.0f + 0.5f).toNumber();
        dfaCount++;
    }

    // ── Called once after test completes ─────────────────────────────────────
    function uploadResult(result as LT1Result, stageResults as Array,
                          numStages as Number) as Void {
        var email    = _readEmail();
        var endpoint = _readEndpoint();

        if (email.length() == 0) {
            // No email configured — save locally only (AppStorage already done
            // by TestOrchestrator), skip upload.
            return;
        }

        var payload = _buildPayload(email, result, stageResults, numStages);

        // Save payload to AppStorage before attempting — so retry works even
        // if the app is killed mid-request.
        try {
            Application.Storage.setValue(KEY_PENDING, payload);
        } catch (ex) { /* storage unavailable — continue anyway */ }

        _post(payload, endpoint);
    }

    // ── Retry any pending upload (call from LT1TestApp.onStart) ──────────────
    function attemptPendingUpload() as Void {
        var pending = null;
        try {
            pending = Application.Storage.getValue(KEY_PENDING);
        } catch (ex) { return; }

        if (pending == null) { return; }

        var endpoint = _readEndpoint();
        _post(pending, endpoint);
    }

    // ── HTTP response callback ────────────────────────────────────────────────
    function onResponse(code as Number, data as Dictionary?) as Void {
        if (code == 200 || code == 201) {
            // Success — clear pending payload.
            try {
                Application.Storage.deleteValue(KEY_PENDING);
            } catch (ex) { /* ignore */ }
        }
        // On failure: payload stays in AppStorage and will be retried next open.
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Private helpers
    // ─────────────────────────────────────────────────────────────────────────

    private function _reset() as Void {
        hrCount      = 0;
        dfaCount     = 0;
        rrCount      = 0;
        hrSampleTick = 0;
        // No need to zero the buffers — we use hrCount/dfaCount/rrCount as bounds.
    }

    private function _readEmail() as String {
        try {
            var v = Application.Properties.getValue("userEmail");
            return (v != null && v instanceof String) ? v : "";
        } catch (ex) {
            return "";
        }
    }

    private function _readEndpoint() as String {
        try {
            var v = Application.Properties.getValue("apiEndpoint");
            return (v != null && v instanceof String && v.length() > 0)
                ? v
                : "https://api.lt1test.app/submit";
        } catch (ex) {
            return "https://api.lt1test.app/submit";
        }
    }

    private function _buildPayload(email as String,
                                    result as LT1Result,
                                    stageResults as Array,
                                    numStages as Number) as Dictionary {
        // ── Stage array ───────────────────────────────────────────────────────
        var stagesArr = [];
        for (var i = 0; i < numStages; i++) {
            var s = stageResults[i] as StageResult;
            stagesArr.add({
                "n"    => s.stageNumber,
                "hr"   => s.meanHr.format("%.1f").toFloat(),
                "pace" => s.meanPace > 0.0f
                              ? (s.meanPace * 1000.0f + 0.5f).toNumber()
                              : 0,
                "dfa"  => s.meanDfaA1 > 0.0f
                              ? (s.meanDfaA1 * 100.0f + 0.5f).toNumber()
                              : -1,
                "val"  => (s.validityScore * 100.0f + 0.5f).toNumber(),
            });
        }

        // ── HR/pace sub-arrays (trim to actual count) ─────────────────────────
        var hrArr   = _trimArray(hrBuf,   hrCount);
        var paceArr = _trimArray(paceBuf, hrCount);

        // ── DFA sub-arrays (watch-side 30 s samples, fallback) ───────────────
        var dfaArr   = _trimArray(dfaBuf,   dfaCount);
        var stageArr = _trimArray(stageBuf, dfaCount);
        var qualArr  = _trimArray(qualBuf,  dfaCount);

        // ── Raw RR intervals (server recomputes DFA from these for max accuracy)
        var rrArr    = _trimArray(rrBuf, rrCount);

        // ── Test date from System clock ───────────────────────────────────────
        var now      = Time.now();
        var cal      = Time.Gregorian.info(now, Time.FORMAT_SHORT);
        var mm       = cal.month < 10 ? "0" + cal.month.toString() : cal.month.toString();
        var dd       = cal.day   < 10 ? "0" + cal.day.toString()   : cal.day.toString();
        var dateStr  = cal.year.toString() + "-" + mm + "-" + dd;

        return {
            "v"          => 1,
            "email"      => email,
            "test_date"  => dateStr,
            "duration_s" => result.testDurationSecs,
            "hr_source"  => result.hrSourceIsChestStrap ? "strap" : "optical",
            "lt1" => {
                "hr"      => result.lt1Hr,
                "pace_sm" => result.lt1Pace,
                "power_w" => result.lt1Power,
                "conf"    => result.confidenceScore,
                "stage"   => result.detectionStage,
                "sig_qual"=> result.signalQualityOverall,
            },
            "stages" => stagesArr,
            "ts" => {
                "hr_interval_s"  => HR_SAMPLE_EVERY,
                "hr"             => hrArr,
                "pace"           => paceArr,
                "dfa_interval_s" => 30,
                "dfa"            => dfaArr,
                "stage"          => stageArr,
                "qual"           => qualArr,
                "rr_ms"          => rrArr,
            },
        };
    }

    private function _trimArray(src as Array, count as Number) as Array {
        var out = new [count];
        for (var i = 0; i < count; i++) { out[i] = src[i]; }
        return out;
    }

    private function _post(payload as Dictionary, endpoint as String) as Void {
        Communications.makeWebRequest(
            endpoint,
            payload,
            {
                :method  => Communications.HTTP_REQUEST_METHOD_POST,
                :headers => { "Content-Type" => "application/json" },
            },
            method(:onResponse)
        );
    }
}
