"""
dfa_recompute.py — high-quality DFA alpha1 recomputation for post-processing.

Why recompute on the backend?
  The watch computes DFA every 30 s with a fixed 256-sample window and 32-bit
  float arithmetic. Here we use:
    - overlapping windows (1-sample stride) → smooth timeseries
    - 64-bit double precision (numpy default)
    - larger windows when data allows (up to 512 samples)
    - the same Kubios-compatible artifact filtering used in RRBuffer.mc

The result is a much smoother DFA α1 curve and a more accurate LT1 estimate.
"""
import logging
from dataclasses import dataclass

import numpy as np
from scipy.signal import medfilt  # for optional smoothing

log = logging.getLogger(__name__)

SCALES_SHORT = [4, 6, 8, 10, 12, 16]   # alpha1: short-range correlations


# ─────────────────────────────────────────────────────────────────────────────
# Core DFA alpha1 function
# ─────────────────────────────────────────────────────────────────────────────

def dfa_alpha1(rr_ms: np.ndarray) -> float:
    """
    Compute DFA alpha1 from an array of RR intervals (milliseconds, float64).
    Returns NaN if input is too short or degenerate.

    Algorithm:
      1. Integrate the mean-centred series: y[k] = Σ (RR[i] - mean_RR)
      2. For each scale n in SCALES_SHORT:
         a. Split y into non-overlapping boxes of length n
         b. Detrend each box (remove linear trend via least squares)
         c. Compute F(n) = sqrt(mean of per-box residual variances)
      3. Fit log F(n) = alpha * log(n) + c  →  slope = alpha1
    """
    n = len(rr_ms)
    if n < 32:
        return float("nan")

    mean_rr = np.mean(rr_ms)
    y = np.cumsum(rr_ms - mean_rr)

    log_n_list: list[float] = []
    log_f_list: list[float] = []

    for scale in SCALES_SHORT:
        n_boxes = n // scale
        if n_boxes < 2:
            continue

        y_trim = y[: n_boxes * scale].reshape(n_boxes, scale)

        # Vectorised least-squares detrend per box.
        x = np.arange(scale, dtype=np.float64)
        x_mean = x.mean()
        x_var  = np.var(x)
        if x_var == 0:
            continue

        y_mean = y_trim.mean(axis=1, keepdims=True)
        slopes = ((y_trim - y_mean) * (x - x_mean)).mean(axis=1, keepdims=True) / x_var
        trend  = slopes * (x - x_mean) + y_mean
        residuals = y_trim - trend
        fn = np.sqrt(np.mean(residuals ** 2))

        if fn <= 0:
            continue

        log_n_list.append(np.log(scale))
        log_f_list.append(np.log(fn))

    if len(log_n_list) < 3:
        return float("nan")

    alpha1 = float(np.polyfit(log_n_list, log_f_list, 1)[0])
    return float(np.clip(alpha1, 0.0, 2.0))


# ─────────────────────────────────────────────────────────────────────────────
# Artifact correction (matches RRBuffer.mc Kubios-style logic)
# ─────────────────────────────────────────────────────────────────────────────

def correct_artifacts(rr_ms: np.ndarray,
                      max_relative_change: float = 0.20,
                      rr_min: float = 300.0,
                      rr_max: float = 2000.0) -> tuple[np.ndarray, float]:
    """
    Apply Kubios-style single-beat interpolation correction.
    Returns (corrected_rr, quality_score).

    quality_score = 1 - (rejected + 0.5 * interpolated) / total
    """
    corrected: list[float] = []
    last_accepted = -1.0
    pending       = -1.0
    rejected      = 0
    interpolated  = 0
    total         = len(rr_ms)

    for rr in rr_ms:
        rr = float(rr)

        # Absolute range: hardware error
        if rr < rr_min or rr > rr_max:
            rejected += 1
            if pending >= 0:
                rejected += 1
                pending = -1.0
            continue

        # First sample
        if last_accepted < 0:
            corrected.append(rr)
            last_accepted = rr
            continue

        rel_change = abs(rr - last_accepted) / last_accepted
        is_clean   = rel_change <= max_relative_change

        if is_clean:
            if pending >= 0:
                interp = (last_accepted + rr) / 2.0
                corrected.append(interp)
                interpolated += 1
                pending = -1.0
            corrected.append(rr)
            last_accepted = rr
        else:
            if pending >= 0:
                rejected += 1
                pending = rr
            else:
                pending = rr

    if total == 0:
        return np.array(corrected, dtype=np.float64), 0.0

    penalty = rejected + interpolated * 0.5
    quality = max(0.0, 1.0 - penalty / total)
    return np.array(corrected, dtype=np.float64), quality


# ─────────────────────────────────────────────────────────────────────────────
# Rolling DFA timeseries
# ─────────────────────────────────────────────────────────────────────────────

@dataclass
class RollingDFAResult:
    center_idx: np.ndarray    # index of the centre sample for each window
    alpha1:     np.ndarray    # DFA alpha1 at each window position
    window:     int
    step:       int


def rolling_dfa(rr_ms: np.ndarray,
                window: int = 256,
                step:   int = 10) -> RollingDFAResult:
    """
    Compute DFA alpha1 over a rolling window.

    window: number of RR intervals per window (~4 min at 60 bpm)
    step:   how many samples to advance between windows
            step=1 gives maximum smoothness but is slower
            step=10 (default) is a good balance

    Returns center_idx (sample positions) and alpha1 values.
    Use these with the original RR timestamps to produce a time axis.
    """
    n = len(rr_ms)
    centers: list[int]   = []
    alphas:  list[float] = []

    for start in range(0, n - window + 1, step):
        chunk  = rr_ms[start: start + window]
        alpha  = dfa_alpha1(chunk)
        center = start + window // 2
        centers.append(center)
        alphas.append(alpha)

    return RollingDFAResult(
        center_idx = np.array(centers, dtype=np.int32),
        alpha1     = np.array(alphas,  dtype=np.float64),
        window     = window,
        step       = step,
    )


def smooth_alpha1(alpha1: np.ndarray, kernel: int = 5) -> np.ndarray:
    """
    Apply a median filter to the alpha1 timeseries to reduce noise.
    kernel must be odd.
    """
    if len(alpha1) < kernel:
        return alpha1.copy()
    kernel = kernel if kernel % 2 == 1 else kernel + 1
    return medfilt(alpha1, kernel_size=kernel)
