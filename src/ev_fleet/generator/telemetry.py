"""Core synthetic telemetry generator.

Design goals:
    * Physically plausible dynamics so downstream analytics are meaningful:
      state of charge (SOC) falls while driving and rises while charging; battery
      and motor temperatures track load; power consumption is positive while driving
      and negative while charging (energy flowing into the pack).
    * A per-vehicle state machine (DRIVING / CHARGING / IDLE) so a vehicle's readings
      form a coherent time series rather than independent random noise.
    * Deterministic output for a given seed, so runs are reproducible and testable.

The generator is a pure producer of ``TelemetryRecord`` objects; it performs no I/O.
Writing to the data lake is the responsibility of the ``lake`` package. This
separation keeps each component independently testable.
"""

from __future__ import annotations

import math
import random
from collections.abc import Iterator
from datetime import datetime, timedelta, timezone
from enum import Enum, auto

from ev_fleet.generator.config import GeneratorConfig
from ev_fleet.schema import TelemetryRecord

# --- Physical constants / plausible bounds -----------------------------------------
# These are illustrative, not manufacturer-accurate; they exist to keep values in a
# realistic range so analytics (and later anomaly detection) behave sensibly.

_NOMINAL_PACK_VOLTAGE = 400.0  # volts at ~mid state of charge
_MIN_SOC = 5.0  # vehicles recharge before fully depleting
_FULL_SOC = 100.0
_CHARGE_TRIGGER_SOC = 20.0  # start charging when SOC drops to this level
_CHARGE_TARGET_SOC = 90.0  # stop charging once SOC reaches this level
_AMBIENT_TEMP_C = 25.0  # baseline temperature the pack relaxes toward

# Geographic bounding box (roughly peninsular India) for plausible lat/long values.
_LAT_MIN, _LAT_MAX = 8.0, 28.0
_LON_MIN, _LON_MAX = 72.0, 88.0


class _State(Enum):
    """Operating state of a vehicle, driving the telemetry dynamics."""

    DRIVING = auto()
    CHARGING = auto()
    IDLE = auto()


class _VehicleSim:
    """Mutable per-vehicle simulation state.

    One instance is created per vehicle. Calling :meth:`step` advances the vehicle by
    one time interval and returns the telemetry reading for that moment.
    """

    def __init__(self, vehicle_id: str, rng: random.Random, interval_seconds: int) -> None:
        self.vehicle_id = vehicle_id
        self._rng = rng
        self._interval_h = interval_seconds / 3600.0  # interval expressed in hours

        # Randomised but plausible initial conditions per vehicle.
        self.soc = rng.uniform(40.0, 90.0)
        self.odometer = rng.uniform(0.0, 50_000.0)
        self.latitude = rng.uniform(_LAT_MIN, _LAT_MAX)
        self.longitude = rng.uniform(_LON_MIN, _LON_MAX)
        self.battery_temp = _AMBIENT_TEMP_C + rng.uniform(-2.0, 5.0)
        self.motor_temp = _AMBIENT_TEMP_C + rng.uniform(-2.0, 5.0)
        self.state = _State.DRIVING if self.soc > _CHARGE_TRIGGER_SOC else _State.CHARGING

    def _update_state(self) -> None:
        """Transition between DRIVING / CHARGING / IDLE based on SOC and chance."""
        if self.state == _State.CHARGING:
            # Keep charging until we reach the target, then resume driving.
            if self.soc >= _CHARGE_TARGET_SOC:
                self.state = _State.DRIVING
        elif self.soc <= _CHARGE_TRIGGER_SOC:
            # Low battery forces a charging session.
            self.state = _State.CHARGING
        else:
            # Occasionally idle (parked) to add realistic variety.
            roll = self._rng.random()
            if roll < 0.05:
                self.state = _State.IDLE
            elif roll < 0.10:
                self.state = _State.DRIVING

    def step(self, ts: datetime) -> TelemetryRecord:
        """Advance the simulation by one interval and return the reading at ``ts``."""
        self._update_state()

        if self.state == _State.DRIVING:
            speed = max(0.0, self._rng.gauss(45.0, 15.0))  # km/h
            distance = speed * self._interval_h  # km travelled this interval
            self.odometer += distance
            # Energy use scales with speed; drain a small SOC fraction per interval.
            power_kw = max(0.0, self._rng.gauss(18.0, 5.0))
            self.soc = max(_MIN_SOC, self.soc - power_kw * self._interval_h * 0.15)
            # Driving heats the pack and motor; relax gently toward a load temp.
            self.battery_temp += (35.0 - self.battery_temp) * 0.05 + self._rng.gauss(0, 0.3)
            self.motor_temp += (60.0 - self.motor_temp) * 0.08 + self._rng.gauss(0, 0.5)
            # Nudge position to simulate movement.
            self._drift_position(distance)
            charging = False

        elif self.state == _State.CHARGING:
            speed = 0.0
            # Charging raises SOC; power_consumption is negative (energy into pack).
            power_kw = -self._rng.uniform(20.0, 50.0)
            self.soc = min(_FULL_SOC, self.soc + (-power_kw) * self._interval_h * 0.20)
            # Charging warms the battery, motor cools toward ambient.
            self.battery_temp += (40.0 - self.battery_temp) * 0.04 + self._rng.gauss(0, 0.3)
            self.motor_temp += (_AMBIENT_TEMP_C - self.motor_temp) * 0.10
            charging = True

        else:  # IDLE
            speed = 0.0
            power_kw = self._rng.uniform(0.0, 0.5)  # small parasitic draw
            self.soc = max(_MIN_SOC, self.soc - 0.001)
            self.battery_temp += (_AMBIENT_TEMP_C - self.battery_temp) * 0.10
            self.motor_temp += (_AMBIENT_TEMP_C - self.motor_temp) * 0.10
            charging = False

        return TelemetryRecord(
            vehicle_id=self.vehicle_id,
            timestamp=ts,
            latitude=round(self.latitude, 6),
            longitude=round(self.longitude, 6),
            battery_soc=round(self.soc, 2),
            battery_voltage=round(self._voltage_from_soc(), 2),
            battery_temperature=round(self.battery_temp, 2),
            motor_temperature=round(self.motor_temp, 2),
            speed=round(speed, 2),
            odometer=round(self.odometer, 2),
            charging_status=charging,
            power_consumption=round(power_kw, 3),
        )

    def _voltage_from_soc(self) -> float:
        """Approximate pack voltage as a mild function of SOC.

        Real cells have a non-linear OCV curve; a small linear term around the
        nominal voltage is enough for plausible synthetic data.
        """
        return _NOMINAL_PACK_VOLTAGE + (self.soc - 50.0) * 0.4

    def _drift_position(self, distance_km: float) -> None:
        """Move the vehicle a small amount in a random heading, clamped to the box."""
        heading = self._rng.uniform(0, 2 * math.pi)
        # ~111 km per degree of latitude; longitude scaled by cos(latitude).
        dlat = (distance_km / 111.0) * math.sin(heading)
        dlon = (distance_km / (111.0 * math.cos(math.radians(self.latitude)))) * math.cos(heading)
        self.latitude = min(_LAT_MAX, max(_LAT_MIN, self.latitude + dlat))
        self.longitude = min(_LON_MAX, max(_LON_MIN, self.longitude + dlon))


def _vehicle_id(index: int) -> str:
    """Format a stable, zero-padded vehicle id, e.g. index 42 -> 'EV-0042'."""
    return f"EV-{index:04d}"


def generate_records(config: GeneratorConfig) -> Iterator[TelemetryRecord]:
    """Yield telemetry records for the whole fleet across the configured window.

    Records are yielded lazily (as an iterator) so very large runs never need to fit
    entirely in memory. The lake writer consumes this stream and batches it per day.

    Ordering: records are emitted grouped by vehicle, then chronologically within a
    vehicle. Downstream partitioning by date does not depend on global ordering.

    Args:
        config: Validated generation parameters.

    Yields:
        TelemetryRecord instances in a deterministic order for the given seed.
    """
    base_rng = random.Random(config.seed)
    start = datetime(
        config.start_date.year,
        config.start_date.month,
        config.start_date.day,
        tzinfo=timezone.utc,
    )
    total_intervals = config.readings_per_vehicle_per_day * config.num_days

    for i in range(config.num_vehicles):
        # Give each vehicle its own RNG derived from the base seed so that adding or
        # removing vehicles does not perturb the others' sequences.
        vehicle_rng = random.Random(base_rng.randint(0, 2**32 - 1))
        sim = _VehicleSim(_vehicle_id(i), vehicle_rng, config.interval_seconds)

        for step_index in range(total_intervals):
            ts = start + timedelta(seconds=step_index * config.interval_seconds)
            yield sim.step(ts)
