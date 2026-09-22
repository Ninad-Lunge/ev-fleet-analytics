"""Pure transform logic for the telemetry pipeline (no Apache Beam dependency).

Separated from the Beam pipeline so these functions can be unit-tested offline,
with no heavy dependencies and no Dataflow cost. The Beam pipeline imports and
wraps these in Map/Filter transforms.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import Any

# Anomaly thresholds, chosen relative to the generator's real value ranges
# (Phase 2 lesson: thresholds must match the data's actual distribution).
BATTERY_TEMP_MAX_C = 38.0
MOTOR_TEMP_MAX_C = 70.0
LOW_SOC_PCT = 15.0


def parse_message(raw: bytes) -> dict[str, Any] | None:
    """Parse a Pub/Sub message body (JSON bytes) into a dict.

    Returns None for anything that fails to parse or is missing required identifying
    fields, so the pipeline can drop invalid records rather than crash. One poison
    message must never stop a streaming job.
    """
    try:
        record = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    if not isinstance(record, dict):
        return None
    if not record.get("vehicle_id") or not record.get("timestamp"):
        return None
    return record


def detect_anomalies(record: dict[str, Any]) -> list[str]:
    """Return a list of anomaly reason codes that apply to this record (may be empty)."""
    reasons: list[str] = []
    if record.get("battery_temperature", 0) > BATTERY_TEMP_MAX_C:
        reasons.append("battery_temp_high")
    if record.get("motor_temperature", 0) > MOTOR_TEMP_MAX_C:
        reasons.append("motor_temp_high")
    if (
        record.get("battery_soc", 100) < LOW_SOC_PCT
        and record.get("speed", 0) > 0
        and not record.get("charging_status", False)
    ):
        reasons.append("low_soc_while_driving")
    return reasons


def enrich(record: dict[str, Any]) -> dict[str, Any]:
    """Project the record to the enriched output shape with anomaly flags + metadata."""
    reasons = detect_anomalies(record)
    return {
        "vehicle_id": record["vehicle_id"],
        "timestamp": record["timestamp"],
        "battery_soc": record.get("battery_soc"),
        "battery_temperature": record.get("battery_temperature"),
        "motor_temperature": record.get("motor_temperature"),
        "speed": record.get("speed"),
        "power_consumption": record.get("power_consumption"),
        "charging_status": record.get("charging_status"),
        "is_anomaly": bool(reasons),
        "anomaly_reason": ",".join(reasons) if reasons else None,
        "processed_at": datetime.now(timezone.utc).isoformat(),
    }
