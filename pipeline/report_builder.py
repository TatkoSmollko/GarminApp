"""
report_builder.py — assembles the final report dictionary from FIT data.

The report dict matches schema.json and is passed to chart_generator and
html_renderer.
"""
import logging
from datetime import datetime, timezone

from fit_parser import FITData, LapSummary, pace_sm_to_min_km

log = logging.getLogger(__name__)


def build(fit_data: FITData, athlete: dict | None = None) -> dict:
    """
    Build a report dictionary from parsed FIT data.

    athlete: optional dict with keys name, age, weight_kg, hr_max, vo2max_estimate.
             Pass None to leave athlete section empty.
    """
    s = fit_data.session

    # ── Athlete ───────────────────────────────────────────────────────────────
    athlete_section = athlete or {
        "name":            "",
        "age":             None,
        "weight_kg":       None,
        "hr_max":          None,
        "vo2max_estimate": None,
    }

    # ── Device ────────────────────────────────────────────────────────────────
    device_section = {
        "model":    s.device_model or "Forerunner 955",
        "firmware": s.firmware or "",
    }

    # ── Test metadata ─────────────────────────────────────────────────────────
    test_date = ""
    start_iso = ""
    if s.start_time:
        if hasattr(s.start_time, "isoformat"):
            start_iso = s.start_time.isoformat()
            test_date = start_iso[:10]
        else:
            test_date = str(s.start_time)[:10]
            start_iso = str(s.start_time)

    # ── HR source ─────────────────────────────────────────────────────────────
    # Derive from signal quality: if overall quality > 0.6 it's likely chest strap.
    is_strap    = s.signal_quality_overall > 0.6
    src_label   = "chest_strap" if is_strap else "optical_wrist"
    src_conf    = s.signal_quality_overall
    src_warnings = []
    if not is_strap:
        src_warnings.append(
            "Optical wrist HR detected — DFA alpha1 may be unreliable. "
            "Use an ANT+ chest strap for accurate LT1 detection."
        )

    # ── LT1 result ────────────────────────────────────────────────────────────
    detected      = s.lt1_hr_bpm > 0.0
    conf_score    = s.lt1_confidence
    conf_label    = _confidence_label(conf_score) if detected else "Not detected"
    lt1_pace_minkm = pace_sm_to_min_km(s.lt1_pace_sm)

    lt1_warnings = _lt1_warnings(fit_data)

    lt1_section = {
        "detected":              detected,
        "lt1_hr_bpm":            round(s.lt1_hr_bpm, 1),
        "lt1_pace_sm":           s.lt1_pace_sm,
        "lt1_pace_min_km":       lt1_pace_minkm,
        "lt1_power_w":           round(s.lt1_power_w, 1),
        "dfa_a1_at_detection":   0.75,
        "detection_stage":       s.detection_stage,
        "confidence_score":      round(conf_score, 3),
        "confidence_label":      conf_label,
        "signal_quality_overall": round(s.signal_quality_overall, 3),
        "warnings":              lt1_warnings,
    }

    # ── Per-stage summary ─────────────────────────────────────────────────────
    stages_section = [_lap_to_stage(lap) for lap in fit_data.laps]

    # ── Timeseries (from RECORD messages with developer fields) ───────────────
    # Only include records that have at least an HR value — filters out
    # spurious record messages added before the activity actually starts.
    ts_section = _build_timeseries(fit_data)

    return {
        "schema_version":        "1.0",
        "test_protocol_version": s.test_protocol_version,
        "generated_at":          datetime.now(timezone.utc).isoformat(),
        "athlete":               athlete_section,
        "device":                device_section,
        "test": {
            "date":          test_date,
            "start_time":    start_iso,
            "duration_secs": int(s.duration_s),
            "sport":         s.sport,
        },
        "hr_source": {
            "is_chest_strap": is_strap,
            "source_label":   src_label,
            "confidence":     round(src_conf, 3),
            "warnings":       src_warnings,
        },
        "lt1_result": lt1_section,
        "stages":     stages_section,
        "timeseries": ts_section,
    }


# ─────────────────────────────────────────────────────────────────────────────
# Private helpers
# ─────────────────────────────────────────────────────────────────────────────

def _lap_to_stage(lap: LapSummary) -> dict:
    pace_minkm = pace_sm_to_min_km(lap.stage_mean_pace_sm)
    return {
        "stage_number":     lap.lap_index + 1,
        "duration_s":       round(lap.duration_s, 0),
        "mean_hr_bpm":      round(lap.stage_mean_hr, 1),
        "mean_pace_sm":     lap.stage_mean_pace_sm,
        "mean_pace_min_km": pace_minkm,
        "mean_dfa_a1":      round(lap.stage_mean_dfa_a1, 3),
        "validity_score":   round(lap.stage_validity_score, 3),
    }


def _build_timeseries(fit_data: FITData) -> dict:
    ts_s, dfa, hr, pace, power, rr_qual, stage, valid = [], [], [], [], [], [], [], []

    for rec in fit_data.records:
        if rec.heart_rate == 0 and rec.dfa_a1 < 0:
            continue  # skip pre-activity padding records

        ts_s.append(rec.elapsed_s)
        hr.append(rec.heart_rate)
        dfa.append(round(rec.dfa_a1, 4))
        # speed m/s → pace s/m (guard against div/0)
        pace.append(round(1.0 / rec.speed_ms, 4) if rec.speed_ms > 0.1 else 0.0)
        power.append(round(rec.power_w, 1))
        rr_qual.append(round(rec.rr_quality, 3))
        stage.append(rec.stage)
        valid.append(rec.valid_window)

    return {
        "timestamps_s":   ts_s,
        "dfa_a1":         dfa,
        "heart_rate_bpm": hr,
        "pace_sm":        pace,
        "power_w":        power,
        "rr_quality":     rr_qual,
        "stage":          stage,
        "valid_window":   valid,
    }


def _confidence_label(score: float) -> str:
    if score >= 0.75:
        return "High"
    if score >= 0.45:
        return "Medium"
    return "Low"


def _lt1_warnings(fit_data: FITData) -> list[str]:
    """Produce human-readable warnings from the data quality."""
    warnings = []
    s = fit_data.session

    if s.signal_quality_overall < 0.6:
        warnings.append(
            f"RR signal quality {s.signal_quality_overall:.0%} — consider repeating "
            "with a chest strap for reliable DFA analysis."
        )

    if s.lt1_confidence < 0.45 and s.lt1_hr_bpm > 0:
        warnings.append(
            "Low confidence in LT1 estimate. Check that intensity increased "
            "progressively across all stages."
        )

    if s.detection_stage in (1, 2):
        warnings.append(
            f"LT1 detected in stage {s.detection_stage} — test may have started "
            "at too high an intensity. Consider repeating with a lower starting pace."
        )

    # Check for non-monotone DFA across laps.
    dfa_vals = [
        lap.stage_mean_dfa_a1 for lap in fit_data.laps
        if lap.stage_mean_dfa_a1 > 0
    ]
    non_mono = sum(
        1 for i in range(1, len(dfa_vals)) if dfa_vals[i] > dfa_vals[i - 1]
    )
    if non_mono > 1:
        warnings.append(
            f"DFA alpha1 increased between {non_mono} stage(s) — signal may have been "
            "disrupted by motion artifact or pace change."
        )

    return warnings
