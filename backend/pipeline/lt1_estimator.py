"""
lt1_estimator.py — Regression-based LT1 heart-rate estimation.

Two approaches, used together:

1. Stage-mean regression  (always available)
   Fit a least-squares line through (mean_HR, mean_DFA) for all valid stages.
   Solve for HR where the line crosses α1 = 0.75.
   Confidence penalised for low R², poor slope, or insufficient data range.

2. Rolling-DFA regression  (available when raw RR intervals are uploaded)
   Use the smooth server-side DFA curve (many points) to fit a more detailed
   weighted regression; the weight at each point is its RR quality score.
   Result is averaged with the stage-mean result for a final estimate.
"""
from __future__ import annotations

import logging
import math
from dataclasses import dataclass

import numpy as np

log = logging.getLogger(__name__)

LT1_THRESHOLD = 0.75   # DFA α1 threshold for aerobic threshold


@dataclass
class LT1Estimate:
    hr_bpm:           float
    confidence:       float   # 0.0 – 1.0
    confidence_label: str     # "High" / "Medium" / "Low" / "Not detected"
    method:           str     # "regression" | "interpolation" | "rolling" | "combined"
    r_squared:        float   # goodness of fit for stage regression
    slope:            float   # dfa / bpm — negative expected
    notes:            list[str]


def estimate_from_stages(
    stage_hr:  list[float],
    stage_dfa: list[float],
    min_stages: int = 3,
) -> LT1Estimate | None:
    """
    OLS linear regression through valid stage (HR, DFA) pairs.
    Returns None if there are fewer than min_stages valid points.

    DFA should decrease with HR, so the slope must be negative and the
    regression line must cross 0.75 within a plausible HR range.
    """
    # Filter out invalid (negative) DFA values
    valid = [(h, d) for h, d in zip(stage_hr, stage_dfa) if d > 0]
    if len(valid) < min_stages:
        log.warning("Only %d valid stages for LT1 regression (need %d)", len(valid), min_stages)
        return None

    hrs  = np.array([v[0] for v in valid], dtype=float)
    dfas = np.array([v[1] for v in valid], dtype=float)

    # Least-squares fit: dfa = a*hr + b
    coeffs  = np.polyfit(hrs, dfas, 1)
    a, b    = float(coeffs[0]), float(coeffs[1])

    # R² for quality assessment
    dfa_hat = np.polyval(coeffs, hrs)
    ss_res  = float(np.sum((dfas - dfa_hat) ** 2))
    ss_tot  = float(np.sum((dfas - np.mean(dfas)) ** 2))
    r2      = 1.0 - ss_res / ss_tot if ss_tot > 1e-9 else 0.0

    # Solve for HR at α1 = 0.75:  0.75 = a*hr + b  →  hr = (0.75 - b) / a
    if abs(a) < 1e-6:
        log.warning("Regression slope near zero — cannot estimate LT1")
        return None

    lt1_hr = (LT1_THRESHOLD - b) / a

    # Sanity: must be within physiological HR range
    hr_min, hr_max = float(np.min(hrs)), float(np.max(hrs))
    if not (80 <= lt1_hr <= 220):
        log.warning("Regression LT1 HR %.1f outside physiological range", lt1_hr)
        return None

    # ── Confidence components ─────────────────────────────────────────────────
    # 1. R² quality
    c_r2 = _clamp(r2, 0.0, 1.0)

    # 2. Slope sign & magnitude (expect a < 0; typically −0.003 to −0.015 /bpm)
    c_slope = 1.0 if a < -0.002 else (0.5 if a < 0 else 0.0)

    # 3. Data range coverage: LT1 HR should sit inside (or just outside) the
    #    measured stage range.
    margin = 0.2 * (hr_max - hr_min)
    if hr_min - margin <= lt1_hr <= hr_max + margin:
        c_range = 1.0
    else:
        c_range = 0.3

    # 4. Number of valid stages
    c_nstages = _clamp((len(valid) - 2) / 4.0, 0.0, 1.0)

    confidence = 0.30 * c_r2 + 0.25 * c_slope + 0.25 * c_range + 0.20 * c_nstages

    notes = []
    if a >= 0:
        notes.append("DFA α1 did not decrease with HR — check stage progression.")
    if r2 < 0.50:
        notes.append(f"Low regression fit quality (R²={r2:.2f}).")
    if lt1_hr < hr_min - 5:
        notes.append("LT1 HR extrapolated below lowest stage — increase warmup intensity.")
    if lt1_hr > hr_max + 5:
        notes.append("LT1 HR extrapolated above highest stage — add harder stages.")

    return LT1Estimate(
        hr_bpm=round(lt1_hr, 1),
        confidence=round(confidence, 3),
        confidence_label=_conf_label(confidence),
        method="regression",
        r_squared=round(r2, 3),
        slope=round(a, 5),
        notes=notes,
    )


def estimate_from_rolling(
    rolling_t:   list[float],
    rolling_dfa: list[float],
    rolling_hr:  list[float],
    quality:     list[float] | None = None,
    stage_labels: list[int] | None = None,
    settling_beats: int = 100,
) -> LT1Estimate | None:
    """
    Regression using the server-computed smooth rolling DFA curve.

    Each (HR, DFA) point from the rolling curve is included, weighted by its
    quality score (if provided) and restricted to analysis windows (after
    settling period within each stage — skip the first `settling_beats` worth
    of data at the start of each new stage).

    Returns None if insufficient data.
    """
    if len(rolling_dfa) < 30:
        return None

    t    = np.array(rolling_t,   dtype=float)
    dfas = np.array(rolling_dfa, dtype=float)
    hrs  = np.array(rolling_hr,  dtype=float)

    # Quality weights (default 1.0)
    if quality is not None and len(quality) == len(dfas):
        weights = np.array(quality, dtype=float)
    else:
        weights = np.ones(len(dfas))

    # Keep only valid (positive) DFA points and valid HR
    valid_mask = (dfas > 0) & (hrs > 40) & (hrs < 220) & (weights > 0.3)
    if valid_mask.sum() < 20:
        log.warning("Too few valid rolling DFA points for regression (%d)", valid_mask.sum())
        return None

    t_v   = t[valid_mask]
    dfa_v = dfas[valid_mask]
    hr_v  = hrs[valid_mask]
    w_v   = weights[valid_mask]

    # Weighted least-squares: dfa = a*hr + b
    W     = np.diag(w_v)
    A     = np.column_stack([hr_v, np.ones(len(hr_v))])
    try:
        AtW   = A.T @ W
        coeffs = np.linalg.solve(AtW @ A, AtW @ dfa_v)
    except np.linalg.LinAlgError:
        return None

    a, b = float(coeffs[0]), float(coeffs[1])
    if abs(a) < 1e-6:
        return None

    lt1_hr = (LT1_THRESHOLD - b) / a
    if not (80 <= lt1_hr <= 220):
        return None

    dfa_hat = A @ coeffs
    ss_res  = float(np.sum(w_v * (dfa_v - dfa_hat) ** 2))
    ss_tot  = float(np.sum(w_v * (dfa_v - np.mean(dfa_v)) ** 2))
    r2      = 1.0 - ss_res / ss_tot if ss_tot > 1e-9 else 0.0

    confidence = _clamp(
        0.40 * _clamp(r2, 0.0, 1.0)
        + 0.35 * (1.0 if a < -0.002 else (0.5 if a < 0 else 0.0))
        + 0.25 * _clamp(valid_mask.sum() / 100.0, 0.0, 1.0),
        0.0, 1.0,
    )

    return LT1Estimate(
        hr_bpm=round(lt1_hr, 1),
        confidence=round(confidence, 3),
        confidence_label=_conf_label(confidence),
        method="rolling",
        r_squared=round(r2, 3),
        slope=round(a, 5),
        notes=[],
    )


def combine(
    stage_est:   LT1Estimate | None,
    rolling_est: LT1Estimate | None,
) -> LT1Estimate | None:
    """
    Weighted average of two estimates; weight = confidence².
    Falls back to whichever is available.
    """
    if stage_est is None and rolling_est is None:
        return None
    if stage_est is None:
        return rolling_est
    if rolling_est is None:
        return stage_est

    w1 = stage_est.confidence ** 2
    w2 = rolling_est.confidence ** 2
    total = w1 + w2
    if total < 1e-9:
        return stage_est  # degenerate — just return stage estimate

    hr_combined   = (w1 * stage_est.hr_bpm + w2 * rolling_est.hr_bpm) / total
    conf_combined = (w1 * stage_est.confidence + w2 * rolling_est.confidence) / total

    notes = list(stage_est.notes)
    for n in rolling_est.notes:
        if n not in notes:
            notes.append(n)

    return LT1Estimate(
        hr_bpm=round(hr_combined, 1),
        confidence=round(conf_combined, 3),
        confidence_label=_conf_label(conf_combined),
        method="combined",
        r_squared=round((stage_est.r_squared + rolling_est.r_squared) / 2, 3),
        slope=round((stage_est.slope + rolling_est.slope) / 2, 5),
        notes=notes,
    )


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

def _clamp(v: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, v))


def _conf_label(score: float) -> str:
    if score >= 0.75: return "High"
    if score >= 0.45: return "Medium"
    return "Low"
