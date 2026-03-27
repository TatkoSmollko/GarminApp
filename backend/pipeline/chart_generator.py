"""
chart_generator.py — produces Plotly figures for the LT1 report.

All figures are returned as Plotly Figure objects.
html_renderer embeds them inline via plotly.io.to_html(full_html=False).

Charts:
  1. dfa_hr_over_time  — DFA α1 + HR on a dual-axis time chart
  2. dfa_vs_stage_hr   — DFA α1 vs mean HR scatter (one point per stage)
  3. pace_power_time   — Pace / Power over time (only if data present)
"""
import logging

import numpy as np
import plotly.graph_objects as go
from plotly.subplots import make_subplots

log = logging.getLogger(__name__)

# Colour constants
C_DFA      = "#4A90D9"    # blue
C_HR       = "#E05C5C"    # red
C_LT1_LINE = "#F5A623"    # orange
C_VALID    = "rgba(100,200,100,0.12)"
C_SETTLING = "rgba(200,200,100,0.08)"
C_PACE     = "#7B68EE"
C_POWER    = "#3CB371"

STAGE_COLOURS = [
    "rgba(100,149,237,0.10)",   # stage 1 — light blue
    "rgba( 60,179,113,0.10)",   # stage 2 — green
    "rgba(255,215,  0,0.10)",   # stage 3 — yellow
    "rgba(255,165,  0,0.10)",   # stage 4 — orange
    "rgba(255, 99, 71,0.10)",   # stage 5 — tomato
    "rgba(220, 20, 60,0.10)",   # stage 6 — crimson
]


# ─────────────────────────────────────────────────────────────────────────────
# 1. DFA α1 + HR over time
# ─────────────────────────────────────────────────────────────────────────────

def dfa_hr_over_time(report: dict) -> go.Figure:
    ts   = report["timeseries"]
    lt1  = report["lt1_result"]

    x           = ts["timestamps_s"]
    dfa_vals    = ts["dfa_a1"]
    hr_vals     = ts["heart_rate_bpm"]
    stages      = ts["stage"]
    valid_flags = ts.get("valid_window", [True] * len(x))
    dfa_source  = ts.get("dfa_source", "watch_30s")
    is_rolling  = dfa_source == "server_rolling"

    if not x:
        return _empty_fig("No timeseries data available")

    x_min = min(x)
    x_max = max(x)

    fig = make_subplots(specs=[[{"secondary_y": True}]])

    # ── Stage background shading ──────────────────────────────────────────────
    _add_stage_shading(fig, x, stages, x_min, x_max)

    # ── DFA α1 line ───────────────────────────────────────────────────────────
    # For rolling (smooth) data: show as a single solid line with higher opacity.
    # For sparse watch data: distinguish valid (analysis) from settling windows.
    if is_rolling:
        # Filter out invalid (-1) values so gaps appear naturally
        dfa_plot = [v if v > 0 else None for v in dfa_vals]
        fig.add_trace(go.Scatter(
            x=x, y=dfa_plot,
            name="DFA α1 (server recomputed)",
            mode="lines",
            line=dict(color=C_DFA, width=2.5),
            connectgaps=False,
        ), secondary_y=False)
    else:
        dfa_valid   = [v if valid_flags[i] and v > 0 else None for i, v in enumerate(dfa_vals)]
        dfa_invalid = [v if not valid_flags[i] and v > 0 else None for i, v in enumerate(dfa_vals)]

        fig.add_trace(go.Scatter(
            x=x, y=dfa_invalid,
            name="DFA α1 (settling)",
            mode="lines",
            line=dict(color=C_DFA, width=1.5, dash="dot"),
            connectgaps=False,
            opacity=0.45,
        ), secondary_y=False)

        fig.add_trace(go.Scatter(
            x=x, y=dfa_valid,
            name="DFA α1 (analysis)",
            mode="lines",
            line=dict(color=C_DFA, width=2.5),
            connectgaps=False,
        ), secondary_y=False)

    # ── LT1 threshold line at 0.75 ────────────────────────────────────────────
    fig.add_hline(
        y=0.75, secondary_y=False,
        line=dict(color=C_LT1_LINE, width=1.5, dash="dash"),
        annotation_text="LT1 threshold (α1 = 0.75)",
        annotation_position="bottom right",
        annotation_font_color=C_LT1_LINE,
    )

    # ── HR line — thin for high-resolution 1 s data, thicker for 5 s ─────────
    hr_line_width = 1.5 if len(hr_vals) > 500 else 2.0
    fig.add_trace(go.Scatter(
        x=x, y=hr_vals,
        name="Heart rate",
        mode="lines",
        line=dict(color=C_HR, width=hr_line_width),
        opacity=0.85,
    ), secondary_y=True)

    # ── LT1 HR horizontal line ────────────────────────────────────────────────
    lt1_hr = lt1.get("lt1_hr_bpm", 0)
    if lt1_hr > 0:
        method = lt1.get("estimation_method", "")
        label  = f"LT1 = {lt1_hr:.0f} bpm"
        if "regression" in method or "combined" in method:
            label += " (regression)"
        fig.add_hline(
            y=lt1_hr, secondary_y=True,
            line=dict(color=C_LT1_LINE, width=1.5, dash="dash"),
            annotation_text=label,
            annotation_position="top right",
            annotation_font_color=C_LT1_LINE,
        )

    # ── Subtitle with DFA source info ─────────────────────────────────────────
    source_label = "DFA recomputed server-side from raw RR" if is_rolling else "DFA from watch (30 s samples)"
    title_text   = f"DFA α1 and Heart Rate over Time<br><sup>{source_label}</sup>"

    fig.update_layout(
        title=title_text,
        xaxis_title="Elapsed time (s)",
        template="plotly_dark",
        legend=dict(orientation="h", yanchor="bottom", y=1.02, xanchor="right", x=1),
        margin=dict(l=60, r=60, t=70, b=50),
        height=440,
    )
    fig.update_yaxes(title_text="DFA α1", secondary_y=False,
                     range=[0.3, 1.3], tickformat=".2f")
    fig.update_yaxes(title_text="Heart rate (bpm)", secondary_y=True,
                     range=[60, 220])

    return fig


# ─────────────────────────────────────────────────────────────────────────────
# 2. DFA α1 vs stage mean HR (scatter + regression)
# ─────────────────────────────────────────────────────────────────────────────

def dfa_vs_stage_hr(report: dict) -> go.Figure:
    stages     = report["stages"]
    lt1_result = report["lt1_result"]

    hr_vals  = [s["mean_hr_bpm"]  for s in stages if s.get("mean_dfa_a1", -1) > 0]
    dfa_vals = [s["mean_dfa_a1"]  for s in stages if s.get("mean_dfa_a1", -1) > 0]
    labels   = [f"S{s['stage_number']}" for s in stages if s.get("mean_dfa_a1", -1) > 0]

    if len(hr_vals) < 2:
        return _empty_fig("Not enough stage data for DFA vs HR plot")

    fig = go.Figure()

    # ── Regression line ───────────────────────────────────────────────────────
    coeffs = np.polyfit(hr_vals, dfa_vals, 1)
    hr_fit = np.linspace(min(hr_vals) - 5, max(hr_vals) + 10, 100)
    dfa_fit = np.polyval(coeffs, hr_fit)

    fig.add_trace(go.Scatter(
        x=hr_fit, y=dfa_fit,
        name="Linear fit",
        mode="lines",
        line=dict(color="rgba(150,150,150,0.6)", width=1.5, dash="dash"),
    ))

    # ── Stage scatter ─────────────────────────────────────────────────────────
    fig.add_trace(go.Scatter(
        x=hr_vals, y=dfa_vals,
        mode="markers+text",
        name="Stage mean",
        marker=dict(size=12, color=C_DFA,
                    line=dict(width=1.5, color="white")),
        text=labels,
        textposition="top center",
        textfont=dict(color="white", size=11),
    ))

    # ── LT1 threshold line ────────────────────────────────────────────────────
    fig.add_hline(
        y=0.75,
        line=dict(color=C_LT1_LINE, width=1.5, dash="dash"),
        annotation_text="α1 = 0.75",
        annotation_position="bottom right",
        annotation_font_color=C_LT1_LINE,
    )

    # ── Mark LT1 HR on the chart ──────────────────────────────────────────────
    lt1_hr = lt1_result.get("lt1_hr_bpm", 0)
    if lt1_hr > 0:
        fig.add_vline(
            x=lt1_hr,
            line=dict(color=C_LT1_LINE, width=1.5, dash="dash"),
            annotation_text=f"LT1 = {lt1_hr:.0f} bpm",
            annotation_position="top right",
            annotation_font_color=C_LT1_LINE,
        )

    fig.update_layout(
        title="DFA α1 vs Stage Mean HR",
        xaxis_title="Mean heart rate (bpm)",
        yaxis_title="DFA α1",
        template="plotly_dark",
        yaxis=dict(range=[0.3, 1.3], tickformat=".2f"),
        margin=dict(l=60, r=60, t=60, b=50),
        height=380,
        showlegend=False,
    )
    return fig


# ─────────────────────────────────────────────────────────────────────────────
# 3. Pace / Power over time (rendered only if data is present)
# ─────────────────────────────────────────────────────────────────────────────

def pace_power_over_time(report: dict) -> go.Figure | None:
    ts      = report["timeseries"]
    x       = ts["timestamps_s"]
    pace    = ts.get("pace_sm", [])
    power   = ts.get("power_w", [])
    stages  = ts.get("stage", [])

    has_pace  = any(p > 0 for p in pace)
    has_power = any(p > 0 for p in power)

    if not has_pace and not has_power:
        return None

    # Determine if we have high-resolution 1 s pace data
    high_res = len(pace) > 500

    fig = go.Figure()

    # ── Stage shading ─────────────────────────────────────────────────────────
    if stages and x:
        _add_stage_shading(fig, x, stages, min(x), max(x))

    if has_pace:
        # Convert s/m → min/km for display.
        # Apply light smoothing for 1 s data to reduce GPS noise (5-point median)
        pace_minkm_raw = [p * 1000 / 60 if p > 0 else None for p in pace]
        if high_res:
            pace_minkm = _smooth_pace(pace_minkm_raw, window=7)
        else:
            pace_minkm = pace_minkm_raw

        fig.add_trace(go.Scatter(
            x=x, y=pace_minkm,
            name="Pace (min/km)",
            mode="lines",
            line=dict(color=C_PACE, width=1.8 if high_res else 2.0),
            connectgaps=False,
        ))

    if has_power:
        fig.add_trace(go.Scatter(
            x=x, y=[p if p > 0 else None for p in power],
            name="Power (W)",
            mode="lines",
            line=dict(color=C_POWER, width=2),
            yaxis="y2",
        ))

    subtitle = "1 s resolution" if high_res else "5 s samples"
    fig.update_layout(
        title=f"Pace and Power over Time<br><sup>{subtitle}</sup>",
        xaxis_title="Elapsed time (s)",
        yaxis_title="Pace (min/km)" if has_pace else "",
        yaxis2=dict(title="Power (W)", overlaying="y", side="right") if has_power else {},
        template="plotly_dark",
        legend=dict(orientation="h", yanchor="bottom", y=1.02),
        margin=dict(l=60, r=60, t=70, b=50),
        height=320,
    )
    # Invert pace axis (lower number = faster = better, shown at top).
    # Cap axis range to avoid GPS spikes dominating.
    if has_pace:
        valid_paces = [p for p in pace_minkm if p is not None]
        if valid_paces:
            p_min = max(2.0, min(valid_paces) - 0.3)
            p_max = min(12.0, max(valid_paces) + 0.5)
            fig.update_yaxes(range=[p_max, p_min],  # inverted
                             selector=dict(title_text="Pace (min/km)"))

    return fig


def _smooth_pace(pace: list, window: int = 7) -> list:
    """Apply a simple moving-average to remove GPS jitter from 1 s pace data."""
    out   = []
    half  = window // 2
    n     = len(pace)
    for i in range(n):
        vals = [pace[j] for j in range(max(0, i - half), min(n, i + half + 1))
                if pace[j] is not None]
        out.append(round(sum(vals) / len(vals), 4) if vals else None)
    return out


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

def _add_stage_shading(fig, x, stages, x_min, x_max):
    """Add coloured background rectangles for each stage."""
    if not stages:
        return

    current_stage = stages[0]
    seg_start     = x[0]

    for i in range(1, len(x)):
        if stages[i] != current_stage or i == len(x) - 1:
            seg_end = x[i]
            if current_stage >= 1 and current_stage <= 6:
                colour = STAGE_COLOURS[current_stage - 1]
                fig.add_vrect(
                    x0=seg_start, x1=seg_end,
                    fillcolor=colour, layer="below", line_width=0,
                    annotation_text=f"S{current_stage}",
                    annotation_position="top left",
                    annotation_font=dict(size=9, color="rgba(200,200,200,0.7)"),
                )
            current_stage = stages[i]
            seg_start     = x[i]


def _empty_fig(message: str) -> go.Figure:
    fig = go.Figure()
    fig.add_annotation(
        text=message, xref="paper", yref="paper",
        x=0.5, y=0.5, showarrow=False,
        font=dict(size=14, color="gray"),
    )
    fig.update_layout(template="plotly_dark", height=300)
    return fig
