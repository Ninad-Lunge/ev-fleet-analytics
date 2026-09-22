"""Configuration for a synthetic telemetry generation run.

Keeping all tunables in one validated dataclass makes runs reproducible and makes
the CLI a thin wrapper: it just builds a ``GeneratorConfig`` and hands it off.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date


@dataclass(slots=True)
class GeneratorConfig:
    """Parameters that fully determine a generation run.

    Defaults follow the Phase 1 plan's "start small" guidance: 100 vehicles, one day,
    one reading per minute. Scale up deliberately once the pipeline works end to end.

    Attributes:
        num_vehicles: Number of distinct vehicles in the fleet.
        start_date: First (UTC) calendar day to generate, inclusive.
        num_days: Number of consecutive days to generate.
        interval_seconds: Seconds between consecutive readings for a vehicle.
        seed: RNG seed; fixing it makes output byte-for-byte reproducible.
    """

    num_vehicles: int = 100
    start_date: date = date(2026, 9, 15)
    num_days: int = 1
    interval_seconds: int = 60
    seed: int = 42

    def __post_init__(self) -> None:
        """Validate parameters up front so failures are clear, not cryptic later."""
        if self.num_vehicles <= 0:
            raise ValueError("num_vehicles must be positive")
        if self.num_days <= 0:
            raise ValueError("num_days must be positive")
        if self.interval_seconds <= 0:
            raise ValueError("interval_seconds must be positive")
        if 86_400 % self.interval_seconds != 0:
            # A day must divide evenly into readings so each day has a whole number
            # of intervals; this keeps per-day partitions uniform.
            raise ValueError("interval_seconds must evenly divide 86400 (one day)")

    @property
    def readings_per_vehicle_per_day(self) -> int:
        """Number of readings emitted for one vehicle over a single day."""
        return 86_400 // self.interval_seconds

    @property
    def total_records(self) -> int:
        """Total number of records the run will produce (useful for logging/sizing)."""
        return self.num_vehicles * self.readings_per_vehicle_per_day * self.num_days
