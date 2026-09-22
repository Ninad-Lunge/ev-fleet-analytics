"""Telemetry schema and domain model.

This module is the single source of truth for the shape of an EV telemetry record.
Both the generator (which produces records) and the lake writer (which serializes
them to Parquet) import from here, so the schema never drifts between components.

The schema mirrors the platform's documented telemetry contract:

    vehicle_id, timestamp, latitude, longitude, battery_soc, battery_voltage,
    battery_temperature, motor_temperature, speed, odometer, charging_status,
    power_consumption
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
from datetime import datetime
from typing import Any

import pyarrow as pa


@dataclass(slots=True)
class TelemetryRecord:
    """A single EV telemetry reading at one point in time.

    Units are documented per field to avoid ambiguity downstream (a common source
    of data-quality bugs in real pipelines).
    """

    vehicle_id: str  # e.g. "EV-0042"
    timestamp: datetime  # UTC event time
    latitude: float  # decimal degrees
    longitude: float  # decimal degrees
    battery_soc: float  # state of charge, percent [0..100]
    battery_voltage: float  # volts
    battery_temperature: float  # degrees Celsius
    motor_temperature: float  # degrees Celsius
    speed: float  # km/h
    odometer: float  # total distance travelled, km
    charging_status: bool  # True while plugged in and charging
    power_consumption: float  # instantaneous power draw, kW (negative while charging)

    def to_dict(self) -> dict[str, Any]:
        """Return a plain dict, suitable for building a DataFrame or JSON."""
        return asdict(self)


# Column order is fixed here and reused everywhere to keep Parquet files consistent.
COLUMNS: tuple[str, ...] = (
    "vehicle_id",
    "timestamp",
    "latitude",
    "longitude",
    "battery_soc",
    "battery_voltage",
    "battery_temperature",
    "motor_temperature",
    "speed",
    "odometer",
    "charging_status",
    "power_consumption",
)


def arrow_schema() -> pa.Schema:
    """Return the explicit PyArrow schema for telemetry Parquet files.

    Declaring the schema explicitly (instead of letting pandas/pyarrow infer it)
    guarantees stable column types across every partition, which keeps BigQuery
    external/native table loads predictable in later phases.
    """
    return pa.schema(
        [
            ("vehicle_id", pa.string()),
            # Timestamps are stored as microsecond-precision UTC timestamps.
            ("timestamp", pa.timestamp("us", tz="UTC")),
            ("latitude", pa.float64()),
            ("longitude", pa.float64()),
            ("battery_soc", pa.float64()),
            ("battery_voltage", pa.float64()),
            ("battery_temperature", pa.float64()),
            ("motor_temperature", pa.float64()),
            ("speed", pa.float64()),
            ("odometer", pa.float64()),
            ("charging_status", pa.bool_()),
            ("power_consumption", pa.float64()),
        ]
    )
