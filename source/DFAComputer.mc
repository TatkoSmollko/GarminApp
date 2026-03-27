// DFAComputer.mc
// Computes DFA alpha1 (Detrended Fluctuation Analysis, short-range exponent).
//
// ============================================================================
// ALGORITHM — step-by-step explanation
// ============================================================================
//
// DFA alpha1 measures the SHORT-RANGE fractal correlation in an RR-interval
// time series.  An alpha1 ≈ 1.0 means pink-noise-like correlations (healthy
// rest), while alpha1 ≈ 0.75 corresponds to the aerobic threshold (LT1), and
// alpha1 → 0.5 means uncorrelated (random walk breakdown at high intensity).
//
// Step 1 — Integrate the mean-subtracted series
//   y[k] = Σ_{i=0}^{k} (RR[i] − mean_RR)
//   This converts the stationary RR sequence into a non-stationary "walk",
//   making the local trend removal in Step 3 meaningful.
//
// Step 2 — Choose a set of box sizes n (scales)
//   For alpha1 (short-range), the convention is n ∈ {4, 6, 8, 10, 12, 16}.
//   Larger n values (>16) capture medium/long-range correlations (alpha2).
//   We use 6 scale points — enough for a stable slope estimate.
//
// Step 3 — For each scale n, detrend each non-overlapping box
//   Divide y[] into ⌊N/n⌋ non-overlapping boxes of length n.
//   In each box, fit a least-squares linear trend (the "local trend").
//   Compute the RMS of residuals = how much the walk deviates from trend.
//   F(n) = sqrt( mean of all per-box residual variances )
//
// Step 4 — Log-log regression
//   If F(n) ~ n^alpha, then log F(n) = alpha * log(n) + const.
//   Fit a straight line to {(log n, log F(n))} over the 6 scale points.
//   The slope of that line is alpha1.
//
// ============================================================================
// WATCH CONSTRAINTS AND APPROXIMATIONS
// ============================================================================
//
// Approximation 1: We use a fixed window of N=256 samples (the full buffer).
//   A sliding-window approach would be more accurate but costs O(N²) per step.
//
// Approximation 2: We precompute sum(i) and sum(i²) for each box size since
//   they only depend on n (not on the data). This reduces per-box work.
//
// Approximation 3: We use Monkey C native float (32-bit). Full DFA in
//   published tools uses 64-bit doubles. This introduces ~1e-6 relative error
//   in F(n) values, which is negligible for alpha1 estimation.
//
// Cost per DFA call: O(N * numScales) float operations ≈ 256 * 6 = 1536 mults.
//   On the FR955 (ARM Cortex-M4 ~200 MHz) this is well under 1 ms.
//   We call it every 30 s, so CPU impact is negligible.
//
// Post-processing note: For the final report, the mobile/backend should re-run
//   DFA using all exported RR intervals with double precision and overlapping
//   windows for a smoother, more accurate time series.

import Toybox.Lang;
import Toybox.Math;

class DFAComputer {

    // ---- Scale set for alpha1 (short-range) ----
    // n values from 4 to 16, 6 points. Expanding beyond 16 would pull towards
    // alpha2 and inflate the slope estimate.
    private const SCALES = [4, 6, 8, 10, 12, 16];
    private const NUM_SCALES = 6;

    // Maximum window size we can process (must match RRBuffer.BUFFER_SIZE).
    private const MAX_N = 256;

    // Working arrays — pre-allocated once to avoid GC pressure on watch.
    private var integrated as Array;   // length MAX_N, the y[] series
    private var workWindow as Array;   // length MAX_N, scratch for copyWindow

    function initialize() {
        integrated = new [MAX_N];
        workWindow = new [MAX_N];
        for (var i = 0; i < MAX_N; i++) {
            integrated[i] = 0.0f;
            workWindow[i] = 0.0f;
        }
    }

    // -------------------------------------------------------------------------
    // compute(rrBuffer)
    //
    // Main entry point.  rrBuffer is an RRBuffer instance.
    // Returns alpha1 as a Float, or -1.0 if insufficient data.
    //
    // Caller should check RRBuffer.isReadyForDFA() before calling, but we
    // guard here as well.
    // -------------------------------------------------------------------------
    function compute(rrBuffer as RRBuffer) as Float {
        var n = rrBuffer.samplesAvailable();
        if (n < 16) { return -1.0f; }  // demo-friendly minimum; real testing should use larger windows
        if (n > MAX_N) { n = MAX_N; }

        // Fetch clean RR window from buffer.
        var filled = rrBuffer.copyWindow(workWindow, n);
        if (filled < 16) { return -1.0f; }
        n = filled;

        // Step 1: compute mean and integrate.
        _integrate(n);

        // Steps 2–3: compute F(n) for each scale.
        // Accumulate log(n) and log(F(n)) for regression.
        var sumLogN  = 0.0f;
        var sumLogF  = 0.0f;
        var sumLogN2 = 0.0f;
        var sumLogNF = 0.0f;
        var validScales = 0;

        for (var si = 0; si < NUM_SCALES; si++) {
            var boxSize = SCALES[si];

            // Need at least 2 full boxes.
            if (n < boxSize * 2) { continue; }

            var fn = _computeF(n, boxSize);
            if (fn <= 0.0f) { continue; }

            var logN = Math.log(boxSize.toFloat(), 10.0f);
            var logF = Math.log(fn, 10.0f);

            sumLogN  += logN;
            sumLogF  += logF;
            sumLogN2 += logN * logN;
            sumLogNF += logN * logF;
            validScales++;
        }

        if (validScales < 3) {
            // Need at least 3 scale points for a stable slope.
            return -1.0f;
        }

        // Step 4: OLS regression   log F = alpha * log n + c
        //   alpha = (k * Σ(logN * logF) - Σ(logN) * Σ(logF))
        //         / (k * Σ(logN²) - Σ(logN)²)
        var k     = validScales.toFloat();
        var denom = k * sumLogN2 - sumLogN * sumLogN;
        if (denom == 0.0f) { return -1.0f; }

        var alpha1 = (k * sumLogNF - sumLogN * sumLogF) / denom;

        // Sanity clip: alpha1 should be in [0.0, 2.0] for any plausible signal.
        if (alpha1 < 0.0f) { alpha1 = 0.0f; }
        if (alpha1 > 2.0f) { alpha1 = 2.0f; }

        return alpha1;
    }

    // -------------------------------------------------------------------------
    // _integrate(n)
    //
    // Fills self.integrated[0..n-1] with the cumulative mean-subtracted RR.
    // y[k] = Σ_{i=0}^{k} (RR[i] − mean_RR)
    // -------------------------------------------------------------------------
    private function _integrate(n as Number) as Void {
        // Compute mean.
        var sum = 0.0f;
        for (var i = 0; i < n; i++) {
            sum += workWindow[i];
        }
        var mean = sum / n.toFloat();

        // Cumulative sum of (RR[i] - mean).
        var cumSum = 0.0f;
        for (var i = 0; i < n; i++) {
            cumSum += workWindow[i] - mean;
            integrated[i] = cumSum;
        }
    }

    // -------------------------------------------------------------------------
    // _computeF(n, boxSize)
    //
    // Computes F(boxSize) = sqrt( mean of per-box residual variances ).
    //
    // For a box of length m, the least-squares linear fit to points
    //   (j, y[start + j]), j = 0..m-1
    // has:
    //   s1  = Σ j        = m*(m-1)/2           (precomputable)
    //   s2  = Σ j²       = m*(m-1)*(2m-1)/6    (precomputable)
    //   sy  = Σ y[.+j]   (data-dependent)
    //   sxy = Σ j*y[.+j] (data-dependent)
    //   slope     = (m*sxy - s1*sy) / (m*s2 - s1*s1)
    //   intercept = (sy - slope*s1) / m
    //   residual² = Σ (y[.+j] - intercept - slope*j)²
    //
    // F(n)² = mean of (residual² / m) over all boxes
    // F(n)  = sqrt(F(n)²)
    // -------------------------------------------------------------------------
    private function _computeF(dataLen as Number, boxSize as Number) as Float {
        var m       = boxSize.toFloat();
        var numBoxes = dataLen / boxSize;  // integer division, partial box ignored

        // Precompute scale-dependent sums.
        var s1 = m * (m - 1.0f) / 2.0f;
        var s2 = m * (m - 1.0f) * (2.0f * m - 1.0f) / 6.0f;
        var denom = m * s2 - s1 * s1;   // denominator for slope formula

        if (denom == 0.0f) { return 0.0f; }

        var totalResidualSq = 0.0f;

        for (var b = 0; b < numBoxes; b++) {
            var start = b * boxSize;

            // Accumulate data-dependent sums over this box.
            var sy  = 0.0f;
            var sxy = 0.0f;
            for (var j = 0; j < boxSize; j++) {
                var y = integrated[start + j];
                sy  += y;
                sxy += j.toFloat() * y;
            }

            // Linear trend coefficients.
            var slope     = (m * sxy - s1 * sy) / denom;
            var intercept = (sy - slope * s1) / m;

            // Sum of squared residuals for this box.
            var boxResidualSq = 0.0f;
            for (var j = 0; j < boxSize; j++) {
                var residual = integrated[start + j] - (intercept + slope * j.toFloat());
                boxResidualSq += residual * residual;
            }

            // Per-box variance contribution.
            totalResidualSq += boxResidualSq / m;
        }

        // F(n) = sqrt( mean per-box variance ).
        var f2 = totalResidualSq / numBoxes.toFloat();
        return Math.sqrt(f2);
    }
}
