"""
api.py — FastAPI backend endpoint that receives LT1 test results from the watch.

The watch POSTs a compact JSON payload (~5-6 KB) directly after the test.
This endpoint:
  1. Validates the payload
  2. Reconstructs a report dict (no FIT file needed)
  3. Generates HTML report with charts
  4. Sends email to the user

Run locally:
  .venv/bin/uvicorn api:app --host 0.0.0.0 --port 8000

Deploy on Railway:
  Procfile: web: uvicorn api:app --host 0.0.0.0 --port $PORT
"""
import logging
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, EmailStr

import math

import config
import chart_generator
import html_renderer
import email_sender
import dfa_recompute
import lt1_estimator

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

app = FastAPI(title="LT1 Step Test API", version="1.0")


# ─────────────────────────────────────────────────────────────────────────────
# Payload schema (mirrors UploadManager._buildPayload on the watch)
# ─────────────────────────────────────────────────────────────────────────────

class LT1Result(BaseModel):
    hr:       float
    pace_sm:  float
    power_w:  float = 0.0
    conf:     float
    stage:    int
    sig_qual: float


class StageData(BaseModel):
    n:    int
    hr:   float
    pace: int     # s/km integer
    dfa:  int     # dfa × 100 integer
    val:  int     # validity × 100 integer


class Timeseries(BaseModel):
    hr_interval_s:  int
    hr:             list[int]
    pace:           list[int]   # s/km integers
    dfa_interval_s: int
    dfa:            list[int]   # dfa × 100 integers
    stage:          list[int]
    qual:           list[int]   # 0-100
    rr_ms:          list[int] = []  # raw per-beat RR intervals in ms (optional)


class WatchPayload(BaseModel):
    v:          int             # schema version
    email:      str
    test_date:  str
    duration_s: int
    hr_source:  str             # "strap" | "optical"
    lt1:        LT1Result
    stages:     list[StageData]
    ts:         Timeseries


# ─────────────────────────────────────────────────────────────────────────────
# Endpoint
# ─────────────────────────────────────────────────────────────────────────────

@app.post("/submit")
async def submit(payload: WatchPayload):
    log.info("Received test from %s  lt1_hr=%.1f  conf=%.2f",
             payload.email, payload.lt1.hr, payload.lt1.conf)

    if payload.v != 1:
        raise HTTPException(400, f"Unsupported payload version: {payload.v}")

    # 1. Build report dict from watch payload (no FIT file needed)
    report = _build_report(payload)

    # 2. Generate charts
    figs = {
        "dfa_hr_time": chart_generator.dfa_hr_over_time(report),
        "dfa_vs_hr":   chart_generator.dfa_vs_stage_hr(report),
        "pace_power":  chart_generator.pace_power_over_time(report),
    }

    # 3. Render HTML report
    date_str  = payload.test_date.replace("-", "")
    safe_name = payload.email.split("@")[0].replace(".", "_")
    out_path  = config.OUTPUT_DIR / f"lt1_report_{date_str}_{safe_name}.html"
    html_renderer.render(report, figs, out_path)

    # 4. Send email
    sent = email_sender.send_report(out_path, report)

    return {
        "status": "ok",
        "report": out_path.name,
        "email_sent": sent,
        "lt1_hr": payload.lt1.hr,
        "confidence": payload.lt1.conf,
    }


@app.get("/health")
async def health():
    return {"status": "ok", "time": datetime.now(timezone.utc).isoformat()}


# ─────────────────────────────────────────────────────────────────────────────
# Report builder from watch payload (no FIT parser needed)
# ─────────────────────────────────────────────────────────────────────────────

def _build_report(p: WatchPayload) -> dict:
    """Reconstruct a full report dict from the compact watch payload.

    If raw RR intervals are present, the server recomputes DFA α1 using
    overlapping 256-beat windows (step=10) for a smooth, high-resolution
    curve.  LT1 is then estimated by weighted regression across all valid
    (HR, DFA) points rather than simple two-stage interpolation.
    """

    is_strap   = p.hr_source == "strap"
    lt1        = p.lt1
    ts         = p.ts
    n_hr       = len(ts.hr)
    n_dfa      = len(ts.dfa)
    elapsed_hr = [i * ts.hr_interval_s for i in range(n_hr)]

    # ── Stage summary section ─────────────────────────────────────────────────
    stages_section = []
    for s in p.stages:
        dfa_val   = s.dfa / 100.0 if s.dfa > 0 else -1.0
        pace_sm_s = s.pace / 1000.0 if s.pace > 0 else 0.0
        stages_section.append({
            "stage_number":     s.n,
            "duration_s":       0,
            "mean_hr_bpm":      round(s.hr, 1),
            "mean_pace_sm":     pace_sm_s,
            "mean_pace_min_km": _pace_skm_to_minkm(s.pace),
            "mean_dfa_a1":      round(dfa_val, 3),
            "validity_score":   round(s.val / 100.0, 2),
        })

    # ── DFA timeseries: server recomputation or watch fallback ────────────────
    rr_raw = ts.rr_ms  # list[int] in ms; may be empty

    if rr_raw and is_strap and len(rr_raw) >= 64:
        log.info("Recomputing DFA from %d raw RR intervals (server-side)", len(rr_raw))
        dfa_t, dfa_vals, rr_quality = _compute_rolling_dfa_timeseries(
            rr_raw, p.duration_s
        )
        # Map each HR sample to the closest rolling DFA point
        dfa_expanded, stage_expanded, valid_expanded, rr_qual_expanded = \
            _align_rolling_to_hr(elapsed_hr, dfa_t, dfa_vals, rr_quality, ts)
        dfa_source = "server_rolling"
    else:
        if rr_raw and not is_strap:
            log.info("RR data present but optical source — skipping server DFA recompute")
        elif rr_raw:
            log.info("Too few RR samples (%d) for server DFA — using watch values", len(rr_raw))
        dfa_expanded, stage_expanded, valid_expanded, rr_qual_expanded = \
            _expand_watch_dfa(elapsed_hr, ts)
        dfa_source = "watch_30s"

    # ── Server-side LT1 regression ────────────────────────────────────────────
    stage_hr  = [s["mean_hr_bpm"]  for s in stages_section]
    stage_dfa = [s["mean_dfa_a1"]  for s in stages_section]

    stage_est   = lt1_estimator.estimate_from_stages(stage_hr, stage_dfa)

    rolling_est = None
    if dfa_source == "server_rolling" and len(dfa_expanded) >= 30:
        rolling_est = lt1_estimator.estimate_from_rolling(
            rolling_t   = elapsed_hr,
            rolling_dfa = dfa_expanded,
            rolling_hr  = [float(h) for h in ts.hr],
            quality     = rr_qual_expanded,
        )

    server_lt1 = lt1_estimator.combine(stage_est, rolling_est)

    # Choose the best LT1 estimate: prefer server regression if more confident
    if server_lt1 is not None and server_lt1.hr_bpm > 0:
        final_hr   = server_lt1.hr_bpm
        final_conf = server_lt1.confidence
        conf_label = server_lt1.confidence_label
        method_note = f"LT1 estimated by server {server_lt1.method} (R²={server_lt1.r_squared:.2f})"
        detected   = True
    elif lt1.hr > 0:
        final_hr   = lt1.hr
        final_conf = lt1.conf
        conf_label = _conf_label(lt1.conf)
        method_note = "LT1 estimated on watch (fallback)"
        detected   = True
    else:
        final_hr   = 0.0
        final_conf = 0.0
        conf_label = "Not detected"
        method_note = ""
        detected   = False

    lt1_pace_minkm = _pace_skm_to_minkm(lt1.pace_sm * 1000) if lt1.pace_sm > 0 else "--"

    # ── Warnings ──────────────────────────────────────────────────────────────
    warnings = []
    if not is_strap:
        warnings.append("Optical wrist HR used — DFA α1 reliability reduced. Use a chest strap.")
    if final_conf < 0.45 and detected:
        warnings.append("Low confidence — check that intensity increased progressively across stages.")
    if server_lt1 is not None:
        warnings.extend(server_lt1.notes)

    pace_sm = [round(v / 1000.0, 4) if v > 0 else 0.0 for v in ts.pace]

    return {
        "schema_version":        "1.0",
        "test_protocol_version": 1,
        "generated_at":          datetime.now(timezone.utc).isoformat(),
        "athlete":  {"name": "", "age": None, "weight_kg": None, "hr_max": None},
        "device":   {"model": "Forerunner 955", "firmware": ""},
        "test": {
            "date":          p.test_date,
            "start_time":    p.test_date + "T00:00:00Z",
            "duration_secs": p.duration_s,
            "sport":         "running",
        },
        "hr_source": {
            "is_chest_strap": is_strap,
            "source_label":   "chest_strap" if is_strap else "optical_wrist",
            "confidence":     lt1.sig_qual,
            "dfa_source":     dfa_source,
            "warnings":       [] if is_strap else ["Optical HR detected"],
        },
        "lt1_result": {
            "detected":               detected,
            "lt1_hr_bpm":             round(final_hr, 1),
            "lt1_pace_sm":            lt1.pace_sm,
            "lt1_pace_min_km":        lt1_pace_minkm,
            "lt1_power_w":            round(lt1.power_w, 1),
            "dfa_a1_at_detection":    0.75,
            "detection_stage":        lt1.stage,
            "confidence_score":       round(final_conf, 3),
            "confidence_label":       conf_label,
            "signal_quality_overall": round(lt1.sig_qual, 3),
            "estimation_method":      method_note,
            "regression_r2":          round(server_lt1.r_squared, 3) if server_lt1 else None,
            "warnings":               warnings,
        },
        "stages": stages_section,
        "timeseries": {
            "timestamps_s":   elapsed_hr,
            "dfa_a1":         dfa_expanded,
            "dfa_source":     dfa_source,
            "heart_rate_bpm": list(ts.hr),
            "pace_sm":        pace_sm,
            "power_w":        [0] * n_hr,
            "rr_quality":     rr_qual_expanded,
            "stage":          stage_expanded,
            "valid_window":   valid_expanded,
        },
    }


# ─────────────────────────────────────────────────────────────────────────────
# Server-side DFA computation helpers
# ─────────────────────────────────────────────────────────────────────────────

def _compute_rolling_dfa_timeseries(
    rr_ms: list[int],
    test_duration_s: int,
    window: int = 256,
    step: int = 10,
) -> tuple[list[float], list[float], list[float]]:
    """
    Artifact-correct the RR intervals, then compute rolling DFA α1.

    Returns:
        t        — timestamps in seconds (centre of each window)
        dfa_vals — DFA α1 values
        quality  — per-window RR quality score [0, 1]
    """
    import numpy as np

    rr_array = [float(r) for r in rr_ms]
    corrected, _ = dfa_recompute.correct_artifacts(rr_array)

    if len(corrected) < window:
        # Fall back to all available data
        window = max(32, len(corrected) // 2)
        step   = max(4, window // 16)

    # Rolling DFA
    windows_dfa = []
    windows_t   = []
    windows_q   = []

    # Cumulative time in seconds from RR intervals
    cum_t = [0.0]
    for rr in corrected:
        cum_t.append(cum_t[-1] + rr / 1000.0)

    i = 0
    while i + window <= len(corrected):
        segment = corrected[i : i + window]
        alpha   = dfa_recompute.dfa_alpha1(segment)
        t_centre = (cum_t[i] + cum_t[i + window]) / 2.0

        # Quality: fraction of un-corrected beats in window (corrected already
        # has artifact interpolations baked in; we use RMS variability as proxy)
        seg_arr = [float(x) for x in segment]
        mean_rr = sum(seg_arr) / len(seg_arr)
        rmssd   = (sum((seg_arr[j+1] - seg_arr[j])**2 for j in range(len(seg_arr)-1))
                   / (len(seg_arr) - 1)) ** 0.5
        # Quality heuristic: high RMSSD variability at rest → good signal
        # At exercise, RMSSD naturally drops — normalise by expected range
        q = min(1.0, rmssd / 15.0)  # 15 ms is rough threshold for acceptable variability

        if alpha is not None and not math.isnan(alpha) and alpha > 0:
            windows_dfa.append(round(alpha, 4))
            windows_t.append(round(t_centre, 1))
            windows_q.append(round(q, 3))

        i += step

    return windows_t, windows_dfa, windows_q


def _align_rolling_to_hr(
    elapsed_hr: list[int],
    dfa_t:      list[float],
    dfa_vals:   list[float],
    rr_quality: list[float],
    ts,
) -> tuple[list[float], list[int], list[bool], list[float]]:
    """
    Map each HR sample timestamp to the nearest rolling DFA value.
    Returns (dfa_expanded, stage_expanded, valid_expanded, rr_qual_expanded).
    """
    n_hr  = len(elapsed_hr)
    n_dfa = len(ts.dfa)   # watch-side DFA for stage labels

    # Build a stage label array aligned to elapsed_hr using watch-side stage buf
    elapsed_dfa_watch = [i * ts.dfa_interval_s for i in range(n_dfa)]
    stage_expanded = []
    valid_expanded = []
    dfa_idx_w      = 0
    for i in range(n_hr):
        t = elapsed_hr[i]
        while dfa_idx_w + 1 < n_dfa and elapsed_dfa_watch[dfa_idx_w + 1] <= t:
            dfa_idx_w += 1
        stage_expanded.append(ts.stage[dfa_idx_w] if dfa_idx_w < n_dfa else 0)
        valid_expanded.append(True)   # all rolling-computed windows are treated as valid

    # Align rolling DFA to HR timestamps using nearest-neighbour
    dfa_expanded    = []
    rr_qual_expanded = []
    j = 0   # pointer into rolling arrays
    n_roll = len(dfa_t)

    for i in range(n_hr):
        t = float(elapsed_hr[i])
        # Advance to the nearest rolling DFA sample
        while j + 1 < n_roll and abs(dfa_t[j + 1] - t) < abs(dfa_t[j] - t):
            j += 1
        if n_roll > 0 and abs(dfa_t[j] - t) < 60.0:   # within 60 s → use it
            dfa_expanded.append(dfa_vals[j])
            rr_qual_expanded.append(rr_quality[j])
        else:
            dfa_expanded.append(-1.0)
            rr_qual_expanded.append(0.0)

    return dfa_expanded, stage_expanded, valid_expanded, rr_qual_expanded


def _expand_watch_dfa(
    elapsed_hr: list[int],
    ts,
) -> tuple[list[float], list[int], list[bool], list[float]]:
    """
    Fallback: expand sparse watch-side DFA samples onto the HR timeline.
    """
    n_hr        = len(elapsed_hr)
    n_dfa       = len(ts.dfa)
    elapsed_dfa = [i * ts.dfa_interval_s for i in range(n_dfa)]

    dfa_expanded    = []
    stage_expanded  = []
    valid_expanded  = []
    rr_qual_expanded = []
    dfa_idx         = 0

    for i in range(n_hr):
        t = elapsed_hr[i]
        while dfa_idx + 1 < n_dfa and elapsed_dfa[dfa_idx + 1] <= t:
            dfa_idx += 1
        raw_dfa = ts.dfa[dfa_idx] / 100.0 if dfa_idx < n_dfa and ts.dfa[dfa_idx] > 0 else -1.0
        dfa_expanded.append(round(raw_dfa, 4))
        stage_expanded.append(ts.stage[dfa_idx] if dfa_idx < n_dfa else 0)
        valid_expanded.append(False)
        q = ts.qual[dfa_idx] / 100.0 if dfa_idx < n_dfa else 0.0
        rr_qual_expanded.append(round(q, 2))

    return dfa_expanded, stage_expanded, valid_expanded, rr_qual_expanded


def _conf_label(score: float) -> str:
    if score >= 0.75: return "High"
    if score >= 0.45: return "Medium"
    return "Low"


def _pace_skm_to_minkm(pace_skm: int | float) -> str:
    """pace_skm = seconds per km (integer or float)."""
    if pace_skm <= 0:
        return "--"
    mins = int(pace_skm // 60)
    secs = int(pace_skm % 60)
    return f"{mins}:{secs:02d}"
