"""
garmin_sync.py — downloads new LT1 Step Test activities from Garmin Connect.

Uses the unofficial python-garminconnect library.
Tracks already-processed activity IDs in a local JSON state file so we never
process the same activity twice.
"""
import json
import logging
from datetime import datetime, timezone, timedelta
from pathlib import Path

from garminconnect import Garmin, GarminConnectAuthenticationError

import config

log = logging.getLogger(__name__)


# ─────────────────────────────────────────────────────────────────────────────
# State management (which activity IDs have already been processed)
# ─────────────────────────────────────────────────────────────────────────────

def _load_state() -> set:
    if config.STATE_FILE.exists():
        with open(config.STATE_FILE) as f:
            return set(json.load(f).get("processed", []))
    return set()


def _save_state(processed_ids: set) -> None:
    with open(config.STATE_FILE, "w") as f:
        json.dump({"processed": list(processed_ids)}, f, indent=2)


# ─────────────────────────────────────────────────────────────────────────────
# Garmin Connect client
# ─────────────────────────────────────────────────────────────────────────────

def _get_client() -> Garmin:
    if not config.GARMIN_EMAIL or not config.GARMIN_PASSWORD:
        raise ValueError("GARMIN_EMAIL and GARMIN_PASSWORD must be set in .env")
    client = Garmin(config.GARMIN_EMAIL, config.GARMIN_PASSWORD)
    client.login()
    log.info("Logged in to Garmin Connect as %s", config.GARMIN_EMAIL)
    return client


# ─────────────────────────────────────────────────────────────────────────────
# Public API
# ─────────────────────────────────────────────────────────────────────────────

def fetch_new_lt1_activities() -> list[Path]:
    """
    Check Garmin Connect for unprocessed LT1 Step Test activities.
    Downloads each FIT file to OUTPUT_DIR and returns the list of saved paths.
    """
    processed = _load_state()
    new_paths: list[Path] = []

    try:
        client = _get_client()
    except GarminConnectAuthenticationError as e:
        log.error("Garmin login failed: %s", e)
        return []

    # Fetch the 20 most recent activities — enough to catch any missed runs.
    try:
        activities = client.get_activities(0, 20)
    except Exception as e:
        log.error("Failed to fetch activity list: %s", e)
        return []

    for act in activities:
        act_id   = str(act.get("activityId", ""))
        act_name = act.get("activityName", "")

        if act_id in processed:
            continue  # already handled

        if config.LT1_ACTIVITY_NAME not in act_name:
            continue  # not an LT1 test

        log.info("Found new LT1 activity: id=%s  name=%s", act_id, act_name)

        # Download original FIT file.
        try:
            fit_bytes = client.download_activity(
                act_id,
                dl_fmt=client.ActivityDownloadFormat.ORIGINAL
            )
        except Exception as e:
            log.error("Failed to download activity %s: %s", act_id, e)
            continue

        # Save to disk.
        date_str = act.get("startTimeLocal", datetime.now().strftime("%Y-%m-%dT%H:%M:%S"))[:10]
        filename = f"lt1_{date_str}_{act_id}.fit"
        out_path = config.OUTPUT_DIR / filename
        out_path.write_bytes(fit_bytes)
        log.info("Saved FIT to %s (%d bytes)", out_path, len(fit_bytes))

        new_paths.append(out_path)
        processed.add(act_id)

    _save_state(processed)
    return new_paths


def load_fit_from_path(fit_path: str | Path) -> Path:
    """
    Accepts a local FIT file path (for manual --fit mode).
    Just validates and returns the Path.
    """
    p = Path(fit_path)
    if not p.exists():
        raise FileNotFoundError(f"FIT file not found: {p}")
    if p.suffix.lower() != ".fit":
        raise ValueError(f"Expected a .fit file, got: {p}")
    return p
