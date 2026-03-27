"""
fit_parser.py — extracts standard fields + LT1 developer fields from a FIT file.

Developer field names must match exactly what FITRecorder.mc writes:
  RECORD  : dfa_a1 (0), rr_quality_score (1), current_stage (2), valid_window_flag (3)
  LAP     : stage_mean_hr (4), stage_mean_pace_sm (5), stage_mean_dfa_a1 (6), stage_validity_score (7)
  SESSION : lt1_hr (8), lt1_pace_sm (9), lt1_power_w (10), lt1_confidence (11),
            detection_stage (12), signal_quality_overall (13), test_protocol_version (14)
"""
import logging
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

import fitparse

log = logging.getLogger(__name__)

# ── Developer field name → our canonical key ─────────────────────────────────
_DEV_RECORD_MAP = {
    "dfa_a1":            "dfa_a1",
    "rr_quality_score":  "rr_quality",
    "current_stage":     "stage",
    "valid_window_flag": "valid_window",
}
_DEV_LAP_MAP = {
    "stage_mean_hr":         "stage_mean_hr",
    "stage_mean_pace_sm":    "stage_mean_pace_sm",
    "stage_mean_dfa_a1":     "stage_mean_dfa_a1",
    "stage_validity_score":  "stage_validity_score",
}
_DEV_SESSION_MAP = {
    "lt1_hr":                "lt1_hr_bpm",
    "lt1_pace_sm":           "lt1_pace_sm",
    "lt1_power_w":           "lt1_power_w",
    "lt1_confidence":        "lt1_confidence",
    "detection_stage":       "detection_stage",
    "signal_quality_overall":"signal_quality_overall",
    "test_protocol_version": "test_protocol_version",
}


# ─────────────────────────────────────────────────────────────────────────────
# Data classes (typed, easy to pass around)
# ─────────────────────────────────────────────────────────────────────────────

@dataclass
class RecordPoint:
    timestamp: datetime | None = None
    elapsed_s: int             = 0       # seconds since test start
    heart_rate: int            = 0
    speed_ms: float            = 0.0     # m/s
    power_w: float             = 0.0
    # developer fields
    dfa_a1:    float           = -1.0
    rr_quality: float          = 0.0
    stage:     int             = 0
    valid_window: bool         = False


@dataclass
class LapSummary:
    lap_index:          int   = 0        # 0-based
    start_time:         datetime | None = None
    duration_s:         float = 0.0
    # developer fields
    stage_mean_hr:      float = 0.0
    stage_mean_pace_sm: float = 0.0
    stage_mean_dfa_a1:  float = -1.0
    stage_validity_score: float = 0.0


@dataclass
class SessionSummary:
    start_time:              datetime | None = None
    duration_s:              float           = 0.0
    sport:                   str             = "running"
    # developer fields — LT1 result
    lt1_hr_bpm:              float           = 0.0
    lt1_pace_sm:             float           = 0.0
    lt1_power_w:             float           = 0.0
    lt1_confidence:          float           = 0.0
    detection_stage:         int             = -1
    signal_quality_overall:  float           = 0.0
    test_protocol_version:   int             = 1
    # device info (from file_id / device_info messages)
    device_model:            str             = ""
    firmware:                str             = ""


@dataclass
class FITData:
    records: list[RecordPoint]  = field(default_factory=list)
    laps:    list[LapSummary]   = field(default_factory=list)
    session: SessionSummary     = field(default_factory=SessionSummary)


# ─────────────────────────────────────────────────────────────────────────────
# Parser
# ─────────────────────────────────────────────────────────────────────────────

def parse(fit_path: Path) -> FITData:
    """
    Parse a FIT file and return a FITData object.
    Raises fitparse.FitParseError on corrupt/incompatible files.
    """
    log.info("Parsing FIT file: %s", fit_path)
    ff = fitparse.FitFile(str(fit_path), data_processor=fitparse.StandardUnitsDataProcessor())

    data = FITData()
    t0: datetime | None = None
    lap_idx = 0

    for msg in ff.get_messages():
        # fitparse stores all fields (standard + developer) in msg.fields.
        # We build one flat dict and split it via our name maps.
        all_fields = {f.name: f.value for f in msg.fields if f.value is not None}
        std     = all_fields   # standard fields use the same dict
        dev_raw = all_fields   # developer fields are accessed by name too

        if msg.name == "record":
            dev = {_DEV_RECORD_MAP[k]: v for k, v in dev_raw.items() if k in _DEV_RECORD_MAP}
            ts = std.get("timestamp")
            if t0 is None and ts is not None:
                t0 = ts

            # speed: StandardUnitsDataProcessor converts to m/s
            speed = std.get("enhanced_speed") or std.get("speed") or 0.0

            rec = RecordPoint(
                timestamp    = ts,
                elapsed_s    = int((ts - t0).total_seconds()) if ts and t0 else 0,
                heart_rate   = int(std.get("heart_rate") or 0),
                speed_ms     = float(speed),
                power_w      = float(std.get("power") or 0.0),
                dfa_a1       = float(dev.get("dfa_a1", -1.0)),
                rr_quality   = float(dev.get("rr_quality", 0.0)) / 100.0,  # stored as 0-100 uint8
                stage        = int(dev.get("stage", 0)),
                valid_window = bool(dev.get("valid_window", 0)),
            )
            data.records.append(rec)

        elif msg.name == "lap":
            dev = {_DEV_LAP_MAP[k]: v for k, v in dev_raw.items() if k in _DEV_LAP_MAP}
            lap = LapSummary(
                lap_index            = lap_idx,
                start_time           = std.get("start_time"),
                duration_s           = float(std.get("total_timer_time") or 0.0),
                stage_mean_hr        = float(dev.get("stage_mean_hr", 0.0)),
                stage_mean_pace_sm   = float(dev.get("stage_mean_pace_sm", 0.0)),
                stage_mean_dfa_a1    = float(dev.get("stage_mean_dfa_a1", -1.0)),
                stage_validity_score = float(dev.get("stage_validity_score", 0.0)),
            )
            data.laps.append(lap)
            lap_idx += 1

        elif msg.name == "session":
            dev = {_DEV_SESSION_MAP[k]: v for k, v in dev_raw.items() if k in _DEV_SESSION_MAP}
            data.session = SessionSummary(
                start_time             = std.get("start_time"),
                duration_s             = float(std.get("total_timer_time") or 0.0),
                sport                  = str(std.get("sport") or "running"),
                lt1_hr_bpm             = float(dev.get("lt1_hr_bpm", 0.0)),
                lt1_pace_sm            = float(dev.get("lt1_pace_sm", 0.0)),
                lt1_power_w            = float(dev.get("lt1_power_w", 0.0)),
                lt1_confidence         = float(dev.get("lt1_confidence", 0.0)),
                detection_stage        = int(dev.get("detection_stage", -1)),
                signal_quality_overall = float(dev.get("signal_quality_overall", 0.0)),
                test_protocol_version  = int(dev.get("test_protocol_version", 1)),
            )

        elif msg.name == "device_info":
            # Best-effort: grab device name / firmware if present.
            product = std.get("garmin_product") or std.get("product")
            fw      = std.get("software_version")
            if product and not data.session.device_model:
                data.session.device_model = str(product)
            if fw and not data.session.firmware:
                data.session.firmware = str(fw)

    log.info(
        "Parsed %d records, %d laps, session lt1_hr=%.1f conf=%.2f",
        len(data.records), len(data.laps),
        data.session.lt1_hr_bpm, data.session.lt1_confidence,
    )
    return data


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

def pace_sm_to_min_km(pace_sm: float) -> str:
    """Convert seconds-per-meter to 'M:SS /km' string."""
    if pace_sm <= 0:
        return "--"
    total = pace_sm * 1000.0   # seconds per km
    mins  = int(total // 60)
    secs  = int(total % 60)
    return f"{mins}:{secs:02d}"
