"""
config.py — loads all settings from .env
"""
import os
from pathlib import Path
from dotenv import load_dotenv

load_dotenv()

# ── Garmin Connect credentials ────────────────────────────────────────────────
GARMIN_EMAIL    = os.getenv("GARMIN_EMAIL", "")
GARMIN_PASSWORD = os.getenv("GARMIN_PASSWORD", "")

# ── Email (SMTP) ──────────────────────────────────────────────────────────────
SMTP_HOST     = os.getenv("SMTP_HOST", "smtp.gmail.com")
SMTP_PORT     = int(os.getenv("SMTP_PORT", "587"))
SMTP_USER     = os.getenv("SMTP_USER", "")
SMTP_PASSWORD = os.getenv("SMTP_PASSWORD", "")  # Gmail: use App Password, not account password
EMAIL_FROM    = os.getenv("EMAIL_FROM", SMTP_USER)
EMAIL_TO      = os.getenv("EMAIL_TO", "")        # comma-separated for multiple recipients

# ── File paths ────────────────────────────────────────────────────────────────
OUTPUT_DIR  = Path(os.getenv("OUTPUT_DIR", str(Path(__file__).parent / "output")))
STATE_FILE  = OUTPUT_DIR / "processed_activities.json"   # tracks which activities were already processed
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

# ── Polling ───────────────────────────────────────────────────────────────────
POLL_INTERVAL_MINUTES = int(os.getenv("POLL_INTERVAL_MINUTES", "30"))

# ── Activity name on Garmin Connect (must match what FITRecorder sets) ────────
LT1_ACTIVITY_NAME = "LT1 Step Test"

# ── DFA recompute on backend (more accurate than watch computation) ───────────
RECOMPUTE_DFA_ON_BACKEND = os.getenv("RECOMPUTE_DFA", "true").lower() == "true"
