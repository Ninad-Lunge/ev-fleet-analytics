"""Tests for the generator and data-lake writer.

These are fast, offline tests (no GCS). They verify:
    * config validation,
    * deterministic generation and record counts,
    * physical plausibility bounds,
    * partitioned Parquet output that round-trips with the declared schema.
"""

from __future__ import annotations

from datetime import date

import pyarrow.parquet as pq
import pytest

from ev_fleet.generator import GeneratorConfig, generate_records
from ev_fleet.lake import LakeLayout, write_local
from ev_fleet.schema import COLUMNS


def test_config_rejects_bad_interval() -> None:
    # 3600 divides 86400, so it is valid; 7000 does not, so it must be rejected.
    GeneratorConfig(interval_seconds=3600)
    with pytest.raises(ValueError):
        GeneratorConfig(interval_seconds=7000)


def test_config_record_math() -> None:
    config = GeneratorConfig(num_vehicles=10, num_days=2, interval_seconds=3600)
    assert config.readings_per_vehicle_per_day == 24
    assert config.total_records == 10 * 24 * 2


def test_generation_is_deterministic() -> None:
    config = GeneratorConfig(num_vehicles=3, num_days=1, interval_seconds=3600, seed=7)
    first = [r.to_dict() for r in generate_records(config)]
    second = [r.to_dict() for r in generate_records(config)]
    assert first == second  # same seed -> identical output


def test_record_count_matches_config() -> None:
    config = GeneratorConfig(num_vehicles=5, num_days=1, interval_seconds=3600)
    records = list(generate_records(config))
    assert len(records) == config.total_records


def test_values_are_physically_plausible() -> None:
    config = GeneratorConfig(num_vehicles=5, num_days=1, interval_seconds=1800)
    for record in generate_records(config):
        assert 0.0 <= record.battery_soc <= 100.0
        assert record.speed >= 0.0
        assert record.odometer >= 0.0
        assert -40.0 <= record.battery_temperature <= 120.0
        # Charging implies energy flowing into the pack (negative power draw).
        if record.charging_status:
            assert record.power_consumption <= 0.0


def test_write_local_produces_partitioned_parquet(tmp_path) -> None:
    config = GeneratorConfig(num_vehicles=4, num_days=2, interval_seconds=3600)
    layout = LakeLayout(root=str(tmp_path / "lake"))

    written = write_local(generate_records(config), layout)
    assert written, "expected at least one Parquet file"

    # Two days requested -> two date= partition directories should exist.
    telemetry_root = tmp_path / "lake" / "raw" / "telemetry"
    partitions = sorted(p.name for p in telemetry_root.iterdir() if p.is_dir())
    assert partitions == [
        f"date={date(2026, 9, 15).isoformat()}",
        f"date={date(2026, 9, 16).isoformat()}",
    ]

    # Every file must round-trip with the canonical column set, and the total row
    # count across all files must equal the configured number of records.
    total_rows = 0
    for path in written:
        table = pq.read_table(path)
        assert table.schema.names == list(COLUMNS)
        total_rows += table.num_rows
    assert total_rows == config.total_records
