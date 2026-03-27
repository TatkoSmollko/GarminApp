"""
html_renderer.py — renders the final HTML report from a report dict + Plotly figures.

Produces a single self-contained HTML file with:
  - summary card (LT1 HR / pace / power / confidence)
  - stage-by-stage table
  - DFA α1 + HR chart
  - DFA vs stage HR scatter
  - optional pace/power chart
  - warnings section
"""
import logging
from datetime import datetime
from pathlib import Path

import plotly.io as pio

log = logging.getLogger(__name__)


def render(report: dict, figures: dict, output_path: Path) -> Path:
    """
    Write the HTML report to output_path.
    figures: dict with keys 'dfa_hr_time', 'dfa_vs_hr', 'pace_power' (optional)
    Returns the output path.
    """
    html = _build_html(report, figures)
    output_path.write_text(html, encoding="utf-8")
    log.info("HTML report written to %s (%d bytes)", output_path, len(html))
    return output_path


def _chart_html(fig) -> str:
    if fig is None:
        return ""
    return pio.to_html(fig, full_html=False, include_plotlyjs=False)


def _build_html(report: dict, figures: dict) -> str:
    lt1    = report["lt1_result"]
    stages = report["stages"]
    athlete = report.get("athlete", {})
    device  = report.get("device", {})
    test    = report.get("test", {})
    hr_src  = report.get("hr_source", {})

    # ── Derived display strings ───────────────────────────────────────────────
    lt1_hr_str    = f"{lt1['lt1_hr_bpm']:.0f} bpm" if lt1["detected"] else "—"
    lt1_pace_str  = lt1.get("lt1_pace_min_km", "--") + " /km" if lt1["detected"] and lt1.get("lt1_pace_sm", 0) > 0 else "—"
    lt1_power_str = f"{lt1['lt1_power_w']:.0f} W"  if lt1["detected"] and lt1.get("lt1_power_w", 0) > 0 else "—"
    conf_score    = lt1["confidence_score"]
    conf_label    = lt1["confidence_label"]
    conf_colour   = "#4caf50" if conf_score >= 0.75 else ("#ff9800" if conf_score >= 0.45 else "#f44336")
    detected_str  = "DETECTED" if lt1["detected"] else "NOT DETECTED"
    detected_col  = "#4caf50" if lt1["detected"] else "#f44336"

    sig_quality   = f'{lt1["signal_quality_overall"]:.0%}'
    src_label     = "Chest strap ✓" if hr_src.get("is_chest_strap") else "Optical ⚠"
    src_col       = "#4caf50"       if hr_src.get("is_chest_strap") else "#ff9800"

    test_date     = test.get("date", "")
    athlete_name  = athlete.get("name", "") or "Athlete"
    device_model  = device.get("model", "FR955")
    duration_min  = int(test.get("duration_secs", 0) // 60)

    all_warnings  = lt1.get("warnings", []) + hr_src.get("warnings", [])

    # ── Stage table rows ──────────────────────────────────────────────────────
    stage_rows = ""
    for s in stages:
        dfa_val  = s.get("mean_dfa_a1", -1)
        dfa_str  = f"{dfa_val:.3f}" if dfa_val > 0 else "—"
        dfa_col  = _dfa_colour(dfa_val)
        val_pct  = f"{s.get('validity_score', 0):.0%}"
        pace_str = s.get("mean_pace_min_km", "--")
        stage_rows += f"""
        <tr>
          <td>Stage {s['stage_number']}</td>
          <td>{s.get('mean_hr_bpm', 0):.0f}</td>
          <td>{pace_str}</td>
          <td style="color:{dfa_col};font-weight:bold">{dfa_str}</td>
          <td>{val_pct}</td>
        </tr>"""

    # ── Warnings ──────────────────────────────────────────────────────────────
    warnings_html = ""
    if all_warnings:
        items = "".join(f"<li>{w}</li>" for w in all_warnings)
        warnings_html = f'<div class="warnings"><h3>⚠ Warnings</h3><ul>{items}</ul></div>'

    # ── Charts ────────────────────────────────────────────────────────────────
    chart1 = _chart_html(figures.get("dfa_hr_time"))
    chart2 = _chart_html(figures.get("dfa_vs_hr"))
    chart3 = _chart_html(figures.get("pace_power"))

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>LT1 Step Test Report — {test_date}</title>
  <script src="https://cdn.plot.ly/plotly-2.32.0.min.js"></script>
  <style>
    :root {{
      --bg:      #1a1a2e;
      --surface: #16213e;
      --card:    #0f3460;
      --accent:  #4A90D9;
      --text:    #e0e0e0;
      --muted:   #888;
    }}
    * {{ box-sizing: border-box; margin: 0; padding: 0; }}
    body {{ background: var(--bg); color: var(--text); font-family: 'Segoe UI', Arial, sans-serif;
            font-size: 15px; line-height: 1.6; }}
    .container {{ max-width: 1100px; margin: 0 auto; padding: 24px 16px; }}
    h1 {{ font-size: 1.6rem; margin-bottom: 4px; }}
    h2 {{ font-size: 1.15rem; color: var(--accent); margin: 28px 0 12px; border-bottom: 1px solid #333; padding-bottom: 6px; }}
    h3 {{ font-size: 1rem; margin-bottom: 8px; }}
    .meta {{ color: var(--muted); font-size: 0.88rem; margin-bottom: 24px; }}
    /* Result card */
    .result-card {{ background: var(--card); border-radius: 12px; padding: 24px;
                    display: flex; flex-wrap: wrap; gap: 24px; margin-bottom: 28px; }}
    .result-main {{ flex: 0 0 auto; }}
    .detected-badge {{ font-size: 0.78rem; font-weight: 700; letter-spacing: 1px;
                       color: {detected_col}; margin-bottom: 6px; }}
    .lt1-hr {{ font-size: 3.5rem; font-weight: 800; color: {detected_col}; line-height: 1; }}
    .lt1-hr-label {{ font-size: 0.85rem; color: var(--muted); margin-top: 2px; }}
    .result-metrics {{ display: flex; flex-wrap: wrap; gap: 20px; align-items: flex-start; }}
    .metric {{ background: rgba(0,0,0,0.25); border-radius: 8px; padding: 12px 18px; min-width: 110px; }}
    .metric-val {{ font-size: 1.4rem; font-weight: 700; }}
    .metric-lbl {{ font-size: 0.78rem; color: var(--muted); }}
    .confidence-bar-wrap {{ width: 100%; margin-top: 16px; }}
    .confidence-bar {{ height: 6px; border-radius: 3px; background: #333; margin-top: 4px; }}
    .confidence-fill {{ height: 6px; border-radius: 3px; background: {conf_colour};
                        width: {conf_score*100:.0f}%; }}
    /* Stage table */
    table {{ width: 100%; border-collapse: collapse; }}
    th {{ text-align: left; padding: 8px 12px; background: var(--card);
          color: var(--muted); font-size: 0.8rem; text-transform: uppercase; letter-spacing: .5px; }}
    td {{ padding: 9px 12px; border-bottom: 1px solid #333; }}
    tr:hover td {{ background: rgba(255,255,255,0.03); }}
    /* Source badge */
    .src-badge {{ display: inline-block; padding: 2px 10px; border-radius: 20px;
                  font-size: 0.78rem; font-weight: 600; background: rgba(0,0,0,0.3);
                  color: {src_col}; border: 1px solid {src_col}; }}
    /* Warnings */
    .warnings {{ background: rgba(245,166,35,0.1); border: 1px solid rgba(245,166,35,0.4);
                 border-radius: 8px; padding: 16px 20px; margin-top: 16px; }}
    .warnings h3 {{ color: #F5A623; margin-bottom: 8px; }}
    .warnings ul {{ padding-left: 18px; }}
    .warnings li {{ margin-bottom: 4px; color: #ccc; font-size: 0.9rem; }}
    /* Charts */
    .chart-wrap {{ background: var(--surface); border-radius: 10px; padding: 12px;
                   margin-bottom: 20px; overflow: hidden; }}
    footer {{ text-align: center; color: var(--muted); font-size: 0.78rem; margin-top: 40px; padding-top: 16px;
              border-top: 1px solid #333; }}
  </style>
</head>
<body>
<div class="container">

  <h1>LT1 Step Test Report</h1>
  <p class="meta">
    {athlete_name} &nbsp;·&nbsp; {test_date} &nbsp;·&nbsp;
    {device_model} &nbsp;·&nbsp; {duration_min} min &nbsp;·&nbsp;
    <span class="src-badge">{src_label}</span>
    &nbsp;·&nbsp; RR quality: {sig_quality}
  </p>

  <!-- ── Result card ──────────────────────────────────────────────────── -->
  <div class="result-card">
    <div class="result-main">
      <div class="detected-badge">{detected_str}</div>
      <div class="lt1-hr">{lt1_hr_str}</div>
      <div class="lt1-hr-label">LT1 Heart Rate</div>
    </div>
    <div class="result-metrics">
      <div class="metric">
        <div class="metric-val">{lt1_pace_str}</div>
        <div class="metric-lbl">LT1 Pace</div>
      </div>
      <div class="metric">
        <div class="metric-val">{lt1_power_str}</div>
        <div class="metric-lbl">LT1 Power</div>
      </div>
      <div class="metric">
        <div class="metric-val" style="color:{conf_colour}">{conf_label}</div>
        <div class="metric-lbl">Confidence</div>
        <div class="confidence-bar">
          <div class="confidence-fill"></div>
        </div>
      </div>
    </div>
  </div>

  {warnings_html}

  <!-- ── Charts ───────────────────────────────────────────────────────── -->
  <h2>DFA α1 and Heart Rate</h2>
  <div class="chart-wrap">{chart1}</div>

  <h2>DFA α1 vs Stage HR</h2>
  <div class="chart-wrap">{chart2}</div>

  {"<h2>Pace / Power</h2><div class='chart-wrap'>" + chart3 + "</div>" if chart3 else ""}

  <!-- ── Stage table ──────────────────────────────────────────────────── -->
  <h2>Stage Summary</h2>
  <table>
    <thead>
      <tr>
        <th>Stage</th><th>Mean HR (bpm)</th><th>Pace</th>
        <th>Mean DFA α1</th><th>Valid windows</th>
      </tr>
    </thead>
    <tbody>{stage_rows}</tbody>
  </table>

  <footer>
    Generated {datetime.now().strftime("%Y-%m-%d %H:%M")} &nbsp;·&nbsp;
    LT1 Step Test v{report.get("test_protocol_version", 1)}
  </footer>
</div>
</body>
</html>"""


def _dfa_colour(val: float) -> str:
    if val <= 0:
        return "#888"
    if val >= 0.85:
        return "#4caf50"
    if val >= 0.75:
        return "#8bc34a"
    if val >= 0.65:
        return "#ff9800"
    return "#f44336"
