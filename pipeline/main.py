"""
main.py — CLI entry point for the LT1 report pipeline.

Usage:
  # Process a specific FIT file (manual mode)
  python main.py --fit /path/to/activity.fit

  # Auto-download new LT1 activities from Garmin Connect
  python main.py --auto

  # Auto + send email
  python main.py --auto --email

  # Run as a daemon, polling every N minutes (set POLL_INTERVAL_MINUTES in .env)
  python main.py --daemon

  # Override athlete name shown in report
  python main.py --fit activity.fit --name "Tomas Vago"
"""
import argparse
import logging
import time
from pathlib import Path

import config
import fit_parser
import report_builder
import chart_generator
import html_renderer
import email_sender
from garmin_sync import fetch_new_lt1_activities, load_fit_from_path

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(__name__)


# ─────────────────────────────────────────────────────────────────────────────
# Core pipeline: one FIT file → one HTML report (+ optional email)
# ─────────────────────────────────────────────────────────────────────────────

def process_fit(fit_path: Path, send_email: bool = False,
                athlete_name: str = "") -> Path:
    """
    Full pipeline for a single FIT file.
    Returns the path of the generated HTML report.
    """
    log.info("Processing: %s", fit_path)

    # 1. Parse FIT
    fit_data = fit_parser.parse(fit_path)

    # 2. Build report dict
    athlete = {"name": athlete_name or "", "age": None, "weight_kg": None,
               "hr_max": None, "vo2max_estimate": None}
    report = report_builder.build(fit_data, athlete=athlete)

    # 3. Generate charts
    figs = {
        "dfa_hr_time": chart_generator.dfa_hr_over_time(report),
        "dfa_vs_hr":   chart_generator.dfa_vs_stage_hr(report),
        "pace_power":  chart_generator.pace_power_over_time(report),
    }

    # 4. Render HTML
    date_str     = report["test"].get("date", "unknown").replace("-", "")
    stem         = fit_path.stem
    out_filename = f"lt1_report_{date_str}_{stem}.html"
    out_path     = config.OUTPUT_DIR / out_filename
    html_renderer.render(report, figs, out_path)

    # 5. Print summary to terminal
    _print_summary(report)

    # 6. Send email (optional)
    if send_email:
        ok = email_sender.send_report(out_path, report)
        if not ok:
            log.warning("Email not sent — check .env SMTP settings")

    return out_path


# ─────────────────────────────────────────────────────────────────────────────
# Summary printer
# ─────────────────────────────────────────────────────────────────────────────

def _print_summary(report: dict) -> None:
    lt1   = report["lt1_result"]
    test  = report.get("test", {})
    sep   = "─" * 44

    print(f"\n{sep}")
    print(f"  LT1 Step Test — {test.get('date', '')}")
    print(sep)

    if lt1["detected"]:
        print(f"  LT1 Heart Rate  : {lt1['lt1_hr_bpm']:.0f} bpm")
        pace = lt1.get("lt1_pace_min_km", "--")
        if pace != "--":
            print(f"  LT1 Pace        : {pace} /km")
        pwr = lt1.get("lt1_power_w", 0)
        if pwr > 0:
            print(f"  LT1 Power       : {pwr:.0f} W")
        print(f"  Confidence      : {lt1['confidence_label']} ({lt1['confidence_score']:.0%})")
    else:
        print("  LT1             : NOT DETECTED")

    print(f"  Signal quality  : {lt1['signal_quality_overall']:.0%}")

    warnings = lt1.get("warnings", [])
    if warnings:
        print(f"\n  ⚠  {len(warnings)} warning(s):")
        for w in warnings:
            # wrap at 60 chars
            print(f"     • {w[:80]}")

    print(sep + "\n")


# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="LT1 Step Test report generator",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--fit",    metavar="FILE",   help="Process a specific FIT file")
    group.add_argument("--auto",   action="store_true", help="Download new activities from Garmin Connect")
    group.add_argument("--daemon", action="store_true", help="Poll Garmin Connect every POLL_INTERVAL_MINUTES")

    parser.add_argument("--email",  action="store_true", help="Send report via email after processing")
    parser.add_argument("--name",   metavar="NAME",      help="Athlete name for the report", default="")

    args = parser.parse_args()

    if args.fit:
        # Manual mode: process a single FIT file.
        fit_path = load_fit_from_path(args.fit)
        out = process_fit(fit_path, send_email=args.email, athlete_name=args.name)
        print(f"Report saved to: {out}")

    elif args.auto:
        # One-shot auto mode: check Garmin Connect for new activities.
        paths = fetch_new_lt1_activities()
        if not paths:
            print("No new LT1 activities found.")
        for p in paths:
            out = process_fit(p, send_email=args.email, athlete_name=args.name)
            print(f"Report saved to: {out}")

    elif args.daemon:
        # Daemon mode: poll on a loop.
        interval = config.POLL_INTERVAL_MINUTES * 60
        log.info("Daemon started — polling every %d min", config.POLL_INTERVAL_MINUTES)
        while True:
            try:
                paths = fetch_new_lt1_activities()
                for p in paths:
                    process_fit(p, send_email=args.email, athlete_name=args.name)
            except Exception as e:
                log.error("Poll cycle error: %s", e)
            log.info("Next poll in %d min", config.POLL_INTERVAL_MINUTES)
            time.sleep(interval)


if __name__ == "__main__":
    main()
