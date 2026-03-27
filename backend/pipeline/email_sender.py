"""
email_sender.py — sends the LT1 report HTML via SMTP.

Gmail setup:
  1. Enable 2FA on your Google account.
  2. Go to myaccount.google.com → Security → App passwords.
  3. Generate an App Password for "Mail".
  4. Put that 16-char password in SMTP_PASSWORD in .env (NOT your normal password).

Other providers: just change SMTP_HOST / SMTP_PORT in .env.
"""
import logging
import smtplib
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.mime.base import MIMEBase
from email import encoders
from pathlib import Path

import config

log = logging.getLogger(__name__)


def send_report(report_path: Path, report: dict) -> bool:
    """
    Send the HTML report file as an email attachment.
    The email body contains a plain-text summary.
    Returns True on success.
    """
    if not config.EMAIL_TO:
        log.warning("EMAIL_TO not set — skipping email send")
        return False

    recipients = [r.strip() for r in config.EMAIL_TO.split(",") if r.strip()]
    lt1        = report["lt1_result"]
    test       = report.get("test", {})
    test_date  = test.get("date", "")

    subject = f"LT1 Step Test — {test_date}"
    body    = _build_body(lt1, report)

    msg = MIMEMultipart("mixed")
    msg["Subject"] = subject
    msg["From"]    = config.EMAIL_FROM
    msg["To"]      = ", ".join(recipients)

    # Plain-text body.
    msg.attach(MIMEText(body, "plain", "utf-8"))

    # Attach the HTML report.
    try:
        with open(report_path, "rb") as f:
            attachment = MIMEBase("text", "html")
            attachment.set_payload(f.read())
            encoders.encode_base64(attachment)
            attachment.add_header(
                "Content-Disposition",
                f'attachment; filename="{report_path.name}"',
            )
            msg.attach(attachment)
    except OSError as e:
        log.error("Failed to attach report file: %s", e)
        return False

    # Send via SMTP.
    try:
        with smtplib.SMTP(config.SMTP_HOST, config.SMTP_PORT) as smtp:
            smtp.ehlo()
            smtp.starttls()
            smtp.login(config.SMTP_USER, config.SMTP_PASSWORD)
            smtp.sendmail(config.EMAIL_FROM, recipients, msg.as_string())
        log.info("Email sent to %s", recipients)
        return True
    except smtplib.SMTPAuthenticationError:
        log.error(
            "SMTP authentication failed — check SMTP_USER and SMTP_PASSWORD. "
            "For Gmail, use an App Password (not your account password)."
        )
        return False
    except Exception as e:
        log.error("Failed to send email: %s", e)
        return False


def _build_body(lt1: dict, report: dict) -> str:
    detected  = lt1["detected"]
    test_date = report.get("test", {}).get("date", "")
    athlete   = report.get("athlete", {}).get("name", "Athlete")

    if not detected:
        return (
            f"LT1 Step Test — {test_date}\n\n"
            "LT1 was NOT detected in this test.\n\n"
            + "\n".join(f"• {w}" for w in lt1.get("warnings", []))
            + "\n\nSee the attached HTML report for details."
        )

    lt1_hr    = f'{lt1["lt1_hr_bpm"]:.0f} bpm'
    lt1_pace  = lt1.get("lt1_pace_min_km", "--")
    lt1_power = f'{lt1["lt1_power_w"]:.0f} W' if lt1.get("lt1_power_w", 0) > 0 else "N/A"
    conf      = lt1["confidence_label"]
    sig_qual  = f'{lt1["signal_quality_overall"]:.0%}'

    lines = [
        f"LT1 Step Test Report — {test_date}",
        f"Athlete: {athlete}",
        "",
        "━━━ LT1 RESULT ━━━",
        f"  Heart rate : {lt1_hr}",
        f"  Pace       : {lt1_pace} /km",
        f"  Power      : {lt1_power}",
        f"  Confidence : {conf}",
        f"  RR quality : {sig_qual}",
        "",
    ]
    if lt1.get("warnings"):
        lines.append("Warnings:")
        lines += [f"  • {w}" for w in lt1["warnings"]]
        lines.append("")

    lines.append("The full interactive report is attached as an HTML file.")
    lines.append("Open it in any browser to view the charts.")

    return "\n".join(lines)
