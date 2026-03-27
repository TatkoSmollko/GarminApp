"""
generate_test_fit.py — generates a realistic dummy LT1 Step Test FIT file.

Writes a valid binary FIT file with:
  - standard record messages (HR, speed)
  - all 15 LT1 developer fields (dfa_a1, rr_quality, stage, ...)
  - 6 lap messages with stage summaries
  - session message with LT1 result

Usage:
  python generate_test_fit.py
  → writes output/dummy_lt1_test.fit

Then test the full pipeline:
  python main.py --fit output/dummy_lt1_test.fit
"""
import struct
import io
import math
import random
from datetime import datetime, timezone
from pathlib import Path

# ── FIT constants ─────────────────────────────────────────────────────────────
FIT_EPOCH = datetime(1989, 12, 31, 0, 0, 0, tzinfo=timezone.utc)

# Base types used in developer field definitions
BASE_TYPE_FLOAT  = 0x84   # 32-bit float
BASE_TYPE_UINT8  = 0x02
BASE_TYPE_UINT16 = 0x84   # reused — FIT uint16 = 0x84 actually float; use 0x84 for float fields
# Correct FIT base types:
BT_ENUM    = 0x00
BT_SINT8   = 0x01
BT_UINT8   = 0x02
BT_SINT16  = 0x83
BT_UINT16  = 0x84
BT_SINT32  = 0x85
BT_UINT32  = 0x86
BT_STRING  = 0x07
BT_FLOAT32 = 0x88
BT_FLOAT64 = 0x89
BT_UINT8Z  = 0x0A
BT_UINT16Z = 0x8B
BT_UINT32Z = 0x8C
BT_BYTE    = 0x0D

# Global message numbers
MESG_FILE_ID     = 0
MESG_RECORD      = 20
MESG_LAP         = 19
MESG_SESSION     = 18
MESG_ACTIVITY    = 34
MESG_DEV_DATA_ID = 207
MESG_FIELD_DESC  = 206

# ── CRC ───────────────────────────────────────────────────────────────────────
_CRC_TABLE = [
    0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
    0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
]

def _calc_crc(data: bytes) -> int:
    crc = 0
    for b in data:
        tmp  = _CRC_TABLE[crc & 0xF]
        crc  = (crc >> 4) & 0x0FFF
        crc ^= tmp ^ _CRC_TABLE[b & 0xF]
        tmp  = _CRC_TABLE[crc & 0xF]
        crc  = (crc >> 4) & 0x0FFF
        crc ^= tmp ^ _CRC_TABLE[(b >> 4) & 0xF]
    return crc


# ── Low-level FIT encoding ────────────────────────────────────────────────────

def _fit_ts(dt: datetime) -> int:
    """Convert datetime to FIT timestamp (seconds since FIT epoch)."""
    return int((dt - FIT_EPOCH).total_seconds())


def _def_msg(local_num: int, global_num: int, fields: list,
             dev_fields: list | None = None) -> bytes:
    """
    Build a FIT definition message.
    fields: list of (field_def_num, size, base_type)
    dev_fields: list of (dev_data_idx, field_num, size) for developer fields

    FIT definition message body layout:
      B  reserved         (0x00)
      B  architecture     (0x00 = little-endian)
      H  global_msg_num   (little-endian)
      B  number_of_fields
      [field_def_num, size, base_type] × n_fields
      B  number_of_dev_fields        (only if has_dev flag set)
      [field_def_num, size, dev_data_index] × n_dev_fields
    """
    has_dev  = bool(dev_fields)
    header   = 0x40 | (0x20 if has_dev else 0x00) | (local_num & 0x0F)

    # reserved, architecture(LE), global_msg_num(LE), n_fields
    body = struct.pack("<BBHB", 0, 0, global_num, len(fields))

    for fnum, fsize, ftype in fields:
        body += struct.pack("BBB", fnum, fsize, ftype)

    if has_dev:
        body += struct.pack("B", len(dev_fields))
        for dev_idx, field_num, fsize in dev_fields:
            body += struct.pack("BBB", field_num, fsize, dev_idx)

    return bytes([header]) + body


def _data_msg(local_num: int, values: list) -> bytes:
    """Build a FIT data message from already-packed field bytes."""
    header = local_num & 0x0F
    return bytes([header]) + b"".join(values)


def _pack_str(s: str, length: int) -> bytes:
    """Null-terminated string padded to `length` bytes."""
    b = s.encode("ascii")[:length - 1] + b"\x00"
    return b.ljust(length, b"\x00")


# ── Physiologically realistic test data generation ────────────────────────────

def _generate_stage_dfa(stage_num: int) -> float:
    """
    Simulate DFA alpha1 declining from ~1.05 (stage 1) to ~0.55 (stage 6).
    LT1 crossing (~0.75) occurs between stage 4 and 5.
    Add small noise to make it realistic.
    """
    # Linear decline from 1.05 → 0.55 over 6 stages, with noise.
    base = 1.05 - (stage_num - 1) * 0.10
    noise = random.gauss(0, 0.03)
    return max(0.50, min(1.20, base + noise))


def _generate_stage_hr(stage_num: int) -> float:
    """HR increases from 125 bpm (stage 1) to ~175 bpm (stage 6)."""
    base = 125 + (stage_num - 1) * 9
    return base + random.gauss(0, 1.5)


def _generate_stage_pace(stage_num: int) -> float:
    """Pace in s/m — decreasing (faster) each stage. Stage 1 ~5:30/km."""
    pace_minkm = 5.50 - (stage_num - 1) * 0.20   # min/km, faster each stage
    pace_sm    = pace_minkm * 60.0 / 1000.0       # s/m
    return pace_sm + random.gauss(0, 0.003)


# ── Main FIT file builder ─────────────────────────────────────────────────────

def generate(output_path: Path, seed: int = 42) -> Path:
    random.seed(seed)
    buf = io.BytesIO()

    # Test configuration (matches production constants)
    WARMUP_S     = 600   # 10 min
    STAGE_S      = 240   #  4 min
    SETTLING_S   = 120   #  2 min (first half of stage = settling)
    TRANSITION_S = 30    # 30 s rest
    N_STAGES     = 6
    DFA_INTERVAL = 30    # seconds between DFA samples

    test_start   = datetime(2024, 6, 15, 9, 0, 0, tzinfo=timezone.utc)
    t_offset     = 0     # elapsed seconds

    # Developer data UUID (arbitrary 16 bytes, but consistent)
    DEV_UUID = bytes([0x4C, 0x54, 0x31, 0x54, 0x65, 0x73, 0x74,
                      0x41, 0x70, 0x70, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])
    DEV_IDX  = 0

    # ── Developer field definitions ──────────────────────────────────────────
    # (name, field_num, base_type, size, units)
    DEV_FIELDS = [
        ("dfa_a1",                 0, BT_FLOAT32, 4, ""),
        ("rr_quality_score",       1, BT_UINT8,   1, "%"),
        ("current_stage",          2, BT_UINT8,   1, ""),
        ("valid_window_flag",      3, BT_UINT8,   1, ""),
        ("stage_mean_hr",          4, BT_FLOAT32, 4, "bpm"),
        ("stage_mean_pace_sm",     5, BT_FLOAT32, 4, "s/m"),
        ("stage_mean_dfa_a1",      6, BT_FLOAT32, 4, ""),
        ("stage_validity_score",   7, BT_FLOAT32, 4, ""),
        ("lt1_hr",                 8, BT_FLOAT32, 4, "bpm"),
        ("lt1_pace_sm",            9, BT_FLOAT32, 4, "s/m"),
        ("lt1_power_w",           10, BT_FLOAT32, 4, "W"),
        ("lt1_confidence",        11, BT_FLOAT32, 4, ""),
        ("detection_stage",       12, BT_UINT8,   1, ""),
        ("signal_quality_overall",13, BT_FLOAT32, 4, ""),
        ("test_protocol_version", 14, BT_UINT8,   1, ""),
    ]

    # ── Local message number assignments ─────────────────────────────────────
    LOCAL_FILE_ID    = 0
    LOCAL_DEV_DATA   = 1
    LOCAL_FIELD_DESC = 2
    LOCAL_RECORD     = 3
    LOCAL_LAP        = 4
    LOCAL_SESSION    = 5
    LOCAL_ACTIVITY   = 6

    # ── Definition: file_id (global 0) ───────────────────────────────────────
    buf.write(_def_msg(LOCAL_FILE_ID, MESG_FILE_ID, [
        (0, 1, BT_ENUM),    # type: 4=activity
        (1, 2, BT_UINT16),  # manufacturer: 1=Garmin
        (2, 2, BT_UINT16),  # product (FR955=3558)
        (4, 4, BT_UINT32),  # time_created
    ]))
    buf.write(_data_msg(LOCAL_FILE_ID, [
        struct.pack("B",  4),
        struct.pack("<H", 1),
        struct.pack("<H", 3558),
        struct.pack("<I", _fit_ts(test_start)),
    ]))

    # ── Developer data ID (global 207) ───────────────────────────────────────
    buf.write(_def_msg(LOCAL_DEV_DATA, MESG_DEV_DATA_ID, [
        (0, 16, BT_BYTE),    # developer_id (UUID)
        (1, 16, BT_BYTE),    # application_id
        (2,  4, BT_UINT32),  # manufacturer_id
        (3,  1, BT_UINT8),   # developer_data_index
        (4,  4, BT_UINT32),  # application_version
    ]))
    buf.write(_data_msg(LOCAL_DEV_DATA, [
        DEV_UUID,
        DEV_UUID,                        # application_id = same
        struct.pack("<I", 0xFFFF),       # manufacturer_id: unknown
        struct.pack("B",  DEV_IDX),
        struct.pack("<I", 100),          # app version 1.00
    ]))

    # ── Field descriptions (global 206) — one per developer field ────────────
    buf.write(_def_msg(LOCAL_FIELD_DESC, MESG_FIELD_DESC, [
        (0,  1, BT_UINT8),   # developer_data_index
        (1,  1, BT_UINT8),   # field_definition_number
        (2,  1, BT_UINT8),   # fit_base_type_id
        (3, 64, BT_STRING),  # field_name (max 64 chars)
        (8, 16, BT_STRING),  # units
    ]))
    for fname, fnum, ftype, _, funits in DEV_FIELDS:
        buf.write(_data_msg(LOCAL_FIELD_DESC, [
            struct.pack("B", DEV_IDX),
            struct.pack("B", fnum),
            struct.pack("B", ftype),
            _pack_str(fname,  64),
            _pack_str(funits, 16),
        ]))

    # ── RECORD definition with developer fields ───────────────────────────────
    # Standard fields in records: timestamp(253), heart_rate(3), speed(6)
    record_dev_fields = [
        (DEV_IDX, 0, 4),   # dfa_a1: float32
        (DEV_IDX, 1, 1),   # rr_quality_score: uint8
        (DEV_IDX, 2, 1),   # current_stage: uint8
        (DEV_IDX, 3, 1),   # valid_window_flag: uint8
    ]
    buf.write(_def_msg(LOCAL_RECORD, MESG_RECORD, [
        (253, 4, BT_UINT32),  # timestamp
        (3,   1, BT_UINT8),   # heart_rate
        (6,   2, BT_UINT16),  # speed (mm/s)
    ], record_dev_fields))

    # ── LAP definition with developer fields ──────────────────────────────────
    lap_dev_fields = [
        (DEV_IDX, 4, 4),   # stage_mean_hr
        (DEV_IDX, 5, 4),   # stage_mean_pace_sm
        (DEV_IDX, 6, 4),   # stage_mean_dfa_a1
        (DEV_IDX, 7, 4),   # stage_validity_score
    ]
    buf.write(_def_msg(LOCAL_LAP, MESG_LAP, [
        (253, 4, BT_UINT32),  # timestamp
        (2,   4, BT_UINT32),  # start_time
        (7,   4, BT_UINT32),  # total_elapsed_time (ms)
        (9,   4, BT_UINT32),  # total_timer_time (ms)
    ], lap_dev_fields))

    # ── SESSION definition with developer fields ──────────────────────────────
    session_dev_fields = [
        (DEV_IDX,  8, 4),   # lt1_hr
        (DEV_IDX,  9, 4),   # lt1_pace_sm
        (DEV_IDX, 10, 4),   # lt1_power_w
        (DEV_IDX, 11, 4),   # lt1_confidence
        (DEV_IDX, 12, 1),   # detection_stage
        (DEV_IDX, 13, 4),   # signal_quality_overall
        (DEV_IDX, 14, 1),   # test_protocol_version
    ]
    buf.write(_def_msg(LOCAL_SESSION, MESG_SESSION, [
        (253, 4, BT_UINT32),  # timestamp
        (2,   4, BT_UINT32),  # start_time
        (7,   4, BT_UINT32),  # total_elapsed_time (ms)
        (9,   4, BT_UINT32),  # total_timer_time (ms)
        (5,   1, BT_ENUM),    # sport: 1=running
        (6,   1, BT_ENUM),    # sub_sport
    ], session_dev_fields))

    # ── ACTIVITY definition ───────────────────────────────────────────────────
    buf.write(_def_msg(LOCAL_ACTIVITY, MESG_ACTIVITY, [
        (253, 4, BT_UINT32),  # timestamp
        (1,   4, BT_UINT32),  # total_timer_time (ms)
        (2,   2, BT_UINT16),  # num_sessions
        (3,   1, BT_ENUM),    # type
        (4,   1, BT_ENUM),    # event
        (5,   1, BT_ENUM),    # event_type
    ]))

    # ── RECORDS — warmup ─────────────────────────────────────────────────────
    for tick in range(0, WARMUP_S, DFA_INTERVAL):
        ts  = _fit_ts(test_start) + t_offset + tick
        hr  = int(random.gauss(128, 2))
        spd = int(1.0 / _generate_stage_pace(1) * 1000)  # mm/s
        dfa = random.gauss(1.05, 0.05)
        buf.write(_data_msg(LOCAL_RECORD, [
            struct.pack("<I", ts),
            struct.pack("B",  hr),
            struct.pack("<H", spd),
            struct.pack("<f", dfa),
            struct.pack("B",  85),   # rr_quality 85%
            struct.pack("B",  0),    # stage=0 (warmup)
            struct.pack("B",  0),    # not valid window
        ]))

    t_offset += WARMUP_S

    # ── RECORDS + LAPS — 6 stages ─────────────────────────────────────────────
    stage_results = []

    for stage in range(1, N_STAGES + 1):
        stage_dfa  = _generate_stage_dfa(stage)
        stage_hr   = _generate_stage_hr(stage)
        stage_pace = _generate_stage_pace(stage)
        lap_start  = _fit_ts(test_start) + t_offset
        valid_dfa_accum = []

        for tick in range(0, STAGE_S, DFA_INTERVAL):
            ts       = _fit_ts(test_start) + t_offset + tick
            in_analysis = tick >= SETTLING_S
            hr       = int(stage_hr + random.gauss(0, 1))
            spd      = int(1.0 / stage_pace * 1000)
            dfa      = stage_dfa + random.gauss(0, 0.03)
            quality  = 92 if in_analysis else 78
            is_valid = 1 if in_analysis and dfa > 0 else 0
            if is_valid:
                valid_dfa_accum.append(dfa)

            buf.write(_data_msg(LOCAL_RECORD, [
                struct.pack("<I", ts),
                struct.pack("B",  max(50, min(220, hr))),
                struct.pack("<H", max(0, spd)),
                struct.pack("<f", dfa),
                struct.pack("B",  quality),
                struct.pack("B",  stage),
                struct.pack("B",  is_valid),
            ]))

        t_offset += STAGE_S

        # Lap message at end of stage
        lap_ts       = _fit_ts(test_start) + t_offset
        mean_dfa_lap = float(sum(valid_dfa_accum) / len(valid_dfa_accum)) if valid_dfa_accum else -1.0
        validity     = len(valid_dfa_accum) / max(1, STAGE_S // DFA_INTERVAL)
        stage_results.append((stage, stage_hr, stage_pace, mean_dfa_lap, validity))

        buf.write(_data_msg(LOCAL_LAP, [
            struct.pack("<I", lap_ts),
            struct.pack("<I", lap_start),
            struct.pack("<I", STAGE_S * 1000),
            struct.pack("<I", STAGE_S * 1000),
            struct.pack("<f", stage_hr),
            struct.pack("<f", stage_pace),
            struct.pack("<f", mean_dfa_lap),
            struct.pack("<f", validity),
        ]))

        # Transition (30 s rest) — just a few records, no DFA
        if stage < N_STAGES:
            for tick in range(0, TRANSITION_S, DFA_INTERVAL):
                ts  = _fit_ts(test_start) + t_offset + tick
                hr  = int(stage_hr - 15 + random.gauss(0, 2))
                spd = int(1.0 / stage_pace * 800)
                buf.write(_data_msg(LOCAL_RECORD, [
                    struct.pack("<I", ts),
                    struct.pack("B",  max(50, min(220, hr))),
                    struct.pack("<H", max(0, spd)),
                    struct.pack("<f", -1.0),   # DFA not valid during transition
                    struct.pack("B",  60),
                    struct.pack("B",  stage),
                    struct.pack("B",  0),
                ]))
            t_offset += TRANSITION_S

    # ── LT1 detection (simulate: interpolate between stage 4 and 5) ───────────
    # Stage 4 DFA ≈ 0.85, Stage 5 DFA ≈ 0.75 → LT1 between them
    s4 = stage_results[3]   # (stage, hr, pace, dfa, validity) — stage 4
    s5 = stage_results[4]   # stage 5
    dfa_a = s4[3]; dfa_b = s5[3]
    t_interp = (0.75 - dfa_a) / (dfa_b - dfa_a) if (dfa_b - dfa_a) != 0 else 0.5
    t_interp = max(0.0, min(1.0, t_interp))
    lt1_hr   = s4[1] + t_interp * (s5[1] - s4[1])
    lt1_pace = s4[2] + t_interp * (s5[2] - s4[2])
    lt1_conf = 0.82  # high confidence for clean simulated data

    total_s    = WARMUP_S + N_STAGES * STAGE_S + (N_STAGES - 1) * TRANSITION_S
    session_ts = _fit_ts(test_start) + total_s

    buf.write(_data_msg(LOCAL_SESSION, [
        struct.pack("<I", session_ts),
        struct.pack("<I", _fit_ts(test_start)),
        struct.pack("<I", total_s * 1000),
        struct.pack("<I", total_s * 1000),
        struct.pack("B",  1),           # sport: running
        struct.pack("B",  0),           # sub_sport: generic
        struct.pack("<f", lt1_hr),
        struct.pack("<f", lt1_pace),
        struct.pack("<f", 0.0),         # power: N/A
        struct.pack("<f", lt1_conf),
        struct.pack("B",  5),           # detection_stage = 5
        struct.pack("<f", 0.88),        # overall signal quality
        struct.pack("B",  1),           # protocol version
    ]))

    buf.write(_data_msg(LOCAL_ACTIVITY, [
        struct.pack("<I", session_ts),
        struct.pack("<I", total_s * 1000),
        struct.pack("<H", 1),   # num_sessions
        struct.pack("B",  0),   # type: manual
        struct.pack("B",  26),  # event: activity
        struct.pack("B",  1),   # event_type: stop
    ]))

    # ── Assemble final FIT file ───────────────────────────────────────────────
    data_bytes = buf.getvalue()
    data_size  = len(data_bytes)
    data_crc   = _calc_crc(data_bytes)

    # File header (14 bytes)
    hdr = struct.pack(
        "<BBHI4s",
        14,            # header_size
        0x10,          # protocol_version (1.0)
        2132,          # profile_version (21.32)
        data_size,     # data_size
        b".FIT",       # data_type
    )
    hdr_crc = struct.pack("<H", _calc_crc(hdr))

    fit_bytes = hdr + hdr_crc + data_bytes + struct.pack("<H", data_crc)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(fit_bytes)
    print(f"✓ Dummy FIT file written: {output_path}  ({len(fit_bytes):,} bytes)")
    print(f"  Simulated LT1: {lt1_hr:.0f} bpm | {lt1_pace*1000/60:.2f} min/km | confidence {lt1_conf:.0%}")
    return output_path


if __name__ == "__main__":
    from pathlib import Path
    out = Path(__file__).parent / "output" / "dummy_lt1_test.fit"
    generate(out)
    print(f"\nNext step:")
    print(f"  .venv/bin/python main.py --fit {out}")
