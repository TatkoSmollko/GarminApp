// SensorLayer.mc
// Reads HR, RR intervals, pace, and running power from Garmin sensor APIs.
//
// Architecture:
//   SensorLayer registers a Sensor data listener and decodes incoming data.
//   It pushes raw RR intervals into RRBuffer and exposes current HR, pace,
//   and power as scalar values for the UI and FIT recorder.
//
// HR source detection:
//   The FR955 can receive HR data from:
//     a) Optical wrist sensor (Garmin Elevate) — noisy for DFA α1
//     b) ANT+ chest strap (HRM-Pro, HRM-Tri, HRM-Run) — clean RR intervals
//     c) Bluetooth HRM — available in CIQ 4.x via extended sensor API
//
//   Only ANT+ devices transmit per-beat RR intervals in the HR message.
//   Wrist optical HR gives only a smoothed HR estimate — no true RR data.
//
    //   We detect the source by inspecting whether heartBeatIntervals data arrives:
    //     - If heartBeatIntervals array is non-empty → external HRM → mark as high confidence
    //     - If heartBeatIntervals is empty → wrist optical → mark as low confidence
//       and derive a synthetic RR from instantaneous HR (crude approximation,
//       not suitable for real DFA analysis, but allows partial operation)
//
// IMPORTANT: Optical-derived synthetic RR intervals have severe limitations.
//   DFA α1 computed from them is NOT physiologically valid for LT1 detection.
//   The app will warn the user and cap the confidence score at 0.3.

import Toybox.Lang;
import Toybox.Sensor;
import Toybox.Math;
import Toybox.Activity;

class SensorLayer {

    // ---- Public state (read by TestOrchestrator and UI) ----
    var currentHr      as Number;   // beats per minute, 0 if no data
    var currentPace    as Float;    // seconds per meter, 0 if no GPS/stride sensor
    var currentPower   as Float;    // watts, 0 if no running power sensor
    var rrQuality      as Float;    // 0.0–1.0: driven by RRBuffer.qualityScore()
    var isChestStrap   as Boolean;  // true = confirmed external HRM
    var hasRRData      as Boolean;  // true = real per-beat RR intervals arriving
    var usingSyntheticRR as Boolean; // true when buffer is currently fed from derived optical RR

    // ---- Private references ----
    private var rrBuffer   as RRBuffer;
    private var isRunning  as Boolean;

    // Track how many consecutive samples came from each source so we don't
    // flip-flop the source label on momentary gaps.
    private var consecutiveRRSamples    as Number;
    private var consecutiveOpticalSamples as Number;
    private const SOURCE_CONFIRM_THRESHOLD = 3;  // samples before flipping label

    function initialize(buffer as RRBuffer) {
        rrBuffer                    = buffer;
        currentHr                   = 0;
        currentPace                 = 0.0f;
        currentPower                = 0.0f;
        rrQuality                   = 0.0f;
        isChestStrap                = false;
        hasRRData                   = false;
        usingSyntheticRR            = false;
        isRunning                   = false;
        consecutiveRRSamples        = 0;
        consecutiveOpticalSamples   = 0;
    }

    // -------------------------------------------------------------------------
    // start() / stop()
    // Register or unregister the sensor data listener.
    // -------------------------------------------------------------------------
    function start() as Void {
        if (isRunning) { return; }

        var options = {
            :period    => 1,              // callback every 1 second
            :sensorTypes => [
                Sensor.SENSOR_HEARTRATE
            ],
            :heartBeatIntervals => {
                :enabled => true
            }
        };

        // CIQ 3.4+ API
        Sensor.registerSensorDataListener(method(:onSensorData), options);
        isRunning = true;
    }

    function stop() as Void {
        if (!isRunning) { return; }
        Sensor.unregisterSensorDataListener();
        isRunning = false;
    }

    // Re-register after the activity session starts so the runtime can bind
    // the active HR source again inside the recording context.
    function restartForActivitySession() as Void {
        _resetSourceDetection();

        if (isRunning) {
            Sensor.unregisterSensorDataListener();
            isRunning = false;
        }

        start();
    }

    // -------------------------------------------------------------------------
    // onSensorData(sensorData)
    // Main sensor callback — called every 1 second by the runtime.
    // -------------------------------------------------------------------------
    function onSensorData(sensorData as Sensor.SensorData) as Void {
        var hrData = sensorData.heartRateData;
        if (hrData != null) {
            // Process RR intervals (per-beat data from an external HRM).
            var rrIntervals = hrData.heartBeatIntervals;
            if (rrIntervals != null && rrIntervals.size() > 0) {
                _processRealRR(rrIntervals);
            } else {
                _processSyntheticRR();
            }
        }

        // Update quality score from buffer.
        rrQuality = rrBuffer.qualityScore();

        // Pace: from Activity.Info (GPS) — CIQ provides this in activity context.
        // We read it here on each sensor tick for convenience.
        _updatePaceAndPower();
    }

    // -------------------------------------------------------------------------
    // _processRealRR(rrArray)
    // Handles actual per-beat RR intervals from an ANT+ chest strap.
    // rrArray contains RR values in milliseconds.
    // -------------------------------------------------------------------------
    private function _processRealRR(rrArray as Array) as Void {
        consecutiveRRSamples++;
        consecutiveOpticalSamples = 0;

        if (consecutiveRRSamples >= SOURCE_CONFIRM_THRESHOLD) {
            isChestStrap = true;
            hasRRData    = true;
            usingSyntheticRR = false;
        }

        for (var i = 0; i < rrArray.size(); i++) {
            var rr = rrArray[i];
            if (rr != null) {
                rrBuffer.addInterval(rr);
            }
        }
    }

    // -------------------------------------------------------------------------
    // _processSyntheticRR()
    // Called when no real RR data arrives — optical wrist HR fallback.
    // We synthesise a single RR = 60000 / HR as a crude approximation.
    //
    // WARNING: This is not physiologically meaningful for DFA analysis.
    // Optical HR is smoothed and decimated; it does not capture beat-to-beat
    // variability. Results should be treated as invalid for LT1 purposes.
    // -------------------------------------------------------------------------
    private function _processSyntheticRR() as Void {
        consecutiveOpticalSamples++;
        consecutiveRRSamples = 0;

        if (consecutiveOpticalSamples >= SOURCE_CONFIRM_THRESHOLD) {
            isChestStrap = false;
            hasRRData    = false;
            usingSyntheticRR = true;
        }

        // Inject a synthetic RR only if HR is valid.
        // Even though this is low quality, it keeps the buffer alive for
        // display purposes. The quality score will be low.
        if (currentHr > 30 && currentHr < 220) {
            var syntheticRR = (60000.0f / currentHr.toFloat()).toNumber();
            rrBuffer.addInterval(syntheticRR);
        }
    }

    // -------------------------------------------------------------------------
    // _updatePaceAndPower()
    // Reads pace from Activity.Info (GPS-based) and power from Sensor if
    // a running power sensor (e.g., Stryd, Garmin Running Power) is paired.
    // -------------------------------------------------------------------------
    private function _updatePaceAndPower() as Void {
        // Activity.Info is available in watch-app context via getActivityInfo().
        var info = Activity.getActivityInfo();
        if (info != null) {
            var hr = info.currentHeartRate;
            if (hr != null && hr > 0) {
                currentHr = hr;
            }

            // currentSpeed is in m/s. Pace = 1 / speed (s/m).
            var speed = info.currentSpeed;
            if (speed != null && speed > 0.1f) {
                currentPace = 1.0f / speed;
            }

            // Running power (available on devices that compute it or via ANT+ pod).
            var power = info.currentPower;
            if (power != null && power > 0) {
                currentPower = power.toFloat();
            }
        }
    }

    // Returns a [0.0, 1.0] source confidence scalar:
    //   1.0 = confirmed chest strap with good RR data
    //   0.5 = uncertain / transitioning
    //   0.3 = confirmed optical (synthetic RR — warn user)
    function sourceConfidence() as Float {
        if (isChestStrap && hasRRData) { return 1.0f; }
        if (!isChestStrap && consecutiveOpticalSamples >= SOURCE_CONFIRM_THRESHOLD) {
            return 0.3f;
        }
        return 0.5f;  // still determining
    }

    // Synthetic RR may be useful for keeping the UI alive, but it must never
    // be treated as valid input for DFA/LT1 detection.
    function canUseRRForDfa() as Boolean {
        return hasRRData && isChestStrap && !usingSyntheticRR;
    }

    private function _resetSourceDetection() as Void {
        isChestStrap              = false;
        hasRRData                 = false;
        usingSyntheticRR          = false;
        consecutiveRRSamples      = 0;
        consecutiveOpticalSamples = 0;
    }
}
