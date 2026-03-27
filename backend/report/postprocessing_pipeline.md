# Post-Processing Pipeline (Outside the Watch)

## Overview

The watch produces a FIT file with standard fields and developer fields.
The mobile/backend pipeline has three responsibilities:
1. Parse the FIT file to extract all data
2. Optionally recompute DFA α1 more accurately from raw RR intervals
3. Generate the JSON report and render charts

---

## Step 1 — Parse the FIT File

Use the Garmin FIT SDK (Python `fitparse`, Go `fit`, Java/Kotlin SDK, or Swift `FitKit`).

### Python example with `fitparse`

```python
import fitparse
from collections import defaultdict

def parse_lt1_fit(fit_path: str) -> dict:
    ff = fitparse.FitFile(fit_path)
    records = []
    laps = []
    session = {}

    DEV_FIELD_MAP = {
        "dfa_a1":                "dfa_a1",
        "rr_quality_score":      "rr_quality",
        "current_stage":         "stage",
        "valid_window_flag":     "valid_window",
        "stage_mean_hr":         "stage_mean_hr",
        "stage_mean_pace_sm":    "stage_mean_pace_sm",
        "stage_mean_dfa_a1":     "stage_mean_dfa_a1",
        "stage_validity_score":  "stage_validity",
        "lt1_hr":                "lt1_hr_bpm",
        "lt1_pace_sm":           "lt1_pace_sm",
        "lt1_power_w":           "lt1_power_w",
        "lt1_confidence":        "confidence_score",
        "detection_stage":       "detection_stage",
        "signal_quality_overall":"signal_quality_overall",
        "test_protocol_version": "test_protocol_version",
    }

    for msg in ff.get_messages():
        row = {f.name: f.value for f in msg.fields}
        dev = {f.name: f.value for f in msg.developer_fields}

        # Map developer fields to our canonical names
        dev_mapped = {DEV_FIELD_MAP[k]: v for k, v in dev.items() if k in DEV_FIELD_MAP}

        if msg.name == "record":
            records.append({**row, **dev_mapped})
        elif msg.name == "lap":
            laps.append({**row, **dev_mapped})
        elif msg.name == "session":
            session = {**row, **dev_mapped}

    return {"records": records, "laps": laps, "session": session}
```

---

## Step 2 — Optional: High-Quality DFA Recomputation

The watch uses a 30-second update interval with a fixed 256-sample window.
Post-processing can use:
- **Overlapping windows** (stride = 1 s) for a smooth time series
- **Double precision** arithmetic
- **Kubios-style artifact correction** (interpolation instead of rejection)
- Larger window sizes if the test is long enough (512 samples)

```python
import numpy as np

def dfa_alpha1(rr_ms: np.ndarray) -> float:
    """
    Compute DFA alpha1 from an array of RR intervals in milliseconds.
    Uses short-range scales n = [4, 6, 8, 10, 12, 16].
    """
    n_samples = len(rr_ms)
    if n_samples < 64:
        return float('nan')

    mean_rr = np.mean(rr_ms)
    y = np.cumsum(rr_ms - mean_rr)       # integrate

    scales = [4, 6, 8, 10, 12, 16]
    fn_values = []

    for n in scales:
        num_boxes = n_samples // n
        if num_boxes < 2:
            continue
        y_trimmed = y[:num_boxes * n].reshape((num_boxes, n))

        # Linear detrend in each box.
        x = np.arange(n, dtype=float)
        # Vectorised least-squares: fit ax+b per row.
        x_mean = x.mean()
        x_var  = np.var(x)
        y_mean = y_trimmed.mean(axis=1, keepdims=True)
        slopes = ((y_trimmed * (x - x_mean)).mean(axis=1, keepdims=True)) / x_var
        trend  = slopes * (x - x_mean) + y_mean
        residuals = y_trimmed - trend
        fn_values.append((n, np.sqrt(np.mean(residuals**2))))

    if len(fn_values) < 3:
        return float('nan')

    log_n = np.log([v[0] for v in fn_values])
    log_f = np.log([v[1] for v in fn_values])
    alpha1 = np.polyfit(log_n, log_f, 1)[0]
    return float(np.clip(alpha1, 0, 2))


def rolling_dfa(rr_ms: np.ndarray, window: int = 256, step: int = 10) -> list:
    """
    Compute DFA alpha1 over a rolling window for smooth time series.
    step = how many samples to advance between windows.
    """
    results = []
    for start in range(0, len(rr_ms) - window + 1, step):
        chunk = rr_ms[start:start + window]
        results.append(dfa_alpha1(chunk))
    return results
```

---

## Step 3 — Assemble the Report JSON

```python
import json
from datetime import datetime, timezone

def build_report(fit_data: dict, athlete: dict, device: dict) -> dict:
    session = fit_data["session"]
    laps    = fit_data["laps"]
    records = fit_data["records"]

    # Extract timeseries from records
    ts, dfa, hr, pace, stage, valid = [], [], [], [], [], []
    t0 = None
    for rec in records:
        ts_raw = rec.get("timestamp")
        if ts_raw is None:
            continue
        if t0 is None:
            t0 = ts_raw
        elapsed = int((ts_raw - t0).total_seconds())
        ts.append(elapsed)
        dfa.append(rec.get("dfa_a1", -1.0))
        hr.append(rec.get("heart_rate", 0))
        pace.append(rec.get("enhanced_speed", 0))
        stage.append(rec.get("stage", 0))
        valid.append(bool(rec.get("valid_window", 0)))

    # Build stage list from lap messages
    stages = []
    for i, lap in enumerate(laps):
        pace_sm = lap.get("stage_mean_pace_sm", 0) or 0
        stages.append({
            "stage_number":  i + 1,
            "mean_hr_bpm":   lap.get("stage_mean_hr", 0),
            "mean_pace_sm":  pace_sm,
            "mean_pace_min_km": _pace_sm_to_min_km(pace_sm),
            "mean_dfa_a1":   lap.get("stage_mean_dfa_a1", -1),
            "validity_score": lap.get("stage_validity", 0),
            "window_count":  lap.get("total_timer_time", 0) // 30,
        })

    lt1_pace_sm = session.get("lt1_pace_sm", 0) or 0
    report = {
        "schema_version":        "1.0",
        "test_protocol_version": session.get("test_protocol_version", 1),
        "generated_at":          datetime.now(timezone.utc).isoformat(),
        "athlete":  athlete,
        "device":   device,
        "test": {
            "date":          str(session.get("start_time", ""))[0:10],
            "start_time":    str(session.get("start_time", "")),
            "duration_secs": session.get("total_timer_time", 0),
            "sport":         "running",
        },
        "hr_source": {
            "is_chest_strap": True,   # derive from device pairing data if available
            "source_label":   "chest_strap",
            "confidence":     1.0,
            "warnings":       [],
        },
        "lt1_result": {
            "detected":              session.get("lt1_hr_bpm", 0) > 0,
            "lt1_hr_bpm":            session.get("lt1_hr_bpm", 0),
            "lt1_pace_sm":           lt1_pace_sm,
            "lt1_pace_min_km":       _pace_sm_to_min_km(lt1_pace_sm),
            "lt1_power_w":           session.get("lt1_power_w", 0),
            "dfa_a1_at_detection":   0.75,
            "detection_stage":       session.get("detection_stage", -1),
            "confidence_score":      session.get("confidence_score", 0),
            "signal_quality_overall": session.get("signal_quality_overall", 0),
            "warnings":              [],
        },
        "stages": stages,
        "timeseries": {
            "timestamps_s":    ts,
            "dfa_a1":          dfa,
            "heart_rate_bpm":  hr,
            "stage":           stage,
            "valid_window":    valid,
        },
    }
    return report


def _pace_sm_to_min_km(pace_sm: float) -> str:
    if pace_sm <= 0:
        return "--"
    total_secs = pace_sm * 1000          # seconds per km
    mins  = int(total_secs // 60)
    secs  = int(total_secs % 60)
    return f"{mins}:{secs:02d}"
```

---

## Step 4 — FIT Developer Field → Report Field Mapping

| FIT Dev Field Name        | Field # | Mesg Type | Report JSON Path                       |
|--------------------------|---------|-----------|----------------------------------------|
| dfa_a1                   | 0       | RECORD    | timeseries.dfa_a1[]                   |
| rr_quality_score         | 1       | RECORD    | timeseries.rr_quality[]               |
| current_stage            | 2       | RECORD    | timeseries.stage[]                    |
| valid_window_flag        | 3       | RECORD    | timeseries.valid_window[]             |
| stage_mean_hr            | 4       | LAP       | stages[i].mean_hr_bpm                 |
| stage_mean_pace_sm       | 5       | LAP       | stages[i].mean_pace_sm                |
| stage_mean_dfa_a1        | 6       | LAP       | stages[i].mean_dfa_a1                 |
| stage_validity_score     | 7       | LAP       | stages[i].validity_score              |
| lt1_hr                   | 8       | SESSION   | lt1_result.lt1_hr_bpm                 |
| lt1_pace_sm              | 9       | SESSION   | lt1_result.lt1_pace_sm                |
| lt1_power_w              | 10      | SESSION   | lt1_result.lt1_power_w                |
| lt1_confidence           | 11      | SESSION   | lt1_result.confidence_score           |
| detection_stage          | 12      | SESSION   | lt1_result.detection_stage            |
| signal_quality_overall   | 13      | SESSION   | lt1_result.signal_quality_overall     |
| test_protocol_version    | 14      | SESSION   | test_protocol_version                 |

---

## Step 5 — Chart Recommendations

Use Plotly, Chart.js, or Vega-Lite on the backend/mobile:

1. **DFA α1 over time** — line chart, x=time, y=dfa_a1, horizontal line at 0.75
   - Colour segments by stage (background shading)
   - Shade settling windows differently from analysis windows
   - Mark detected LT1 crossing with a vertical line

2. **HR over time** — overlay on the same x-axis
   - Add horizontal line at lt1_hr_bpm

3. **DFA α1 vs HR** — scatter, one point per stage mean
   - Fit a regression line through the stage means
   - Mark 0.75 with horizontal reference line
   - The crossing of the regression line with 0.75 is the LT1 HR

4. **Pace / Power over time** — separate panel below HR

---

## Notes on Backward Compatibility

- Always check `schema_version` before parsing.
- New fields added in future versions must be optional (no breaking changes).
- `test_protocol_version` lets the backend apply version-specific logic
  (e.g., protocol v2 might change stage durations).
- Store the raw FIT file — it is the ground truth. The JSON report is derived.
