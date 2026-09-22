# EV Fleet Analytics Platform

A project-driven GCP Data Engineering capstone. You learn each GCP data service only
when a phase of the project requires it.

**Domain:** You are the data engineer for an EV company with a (nominal) fleet of
10,000 vehicles emitting telemetry. The platform grows incrementally from a local
data lake to a full streaming + batch + ML pipeline on GCP.

> **Volume rule:** keep the *narrative* at 10,000 vehicles but the *actual* dataset
> tiny and sampled so everything stays within free tiers. Never generate production
> volume into BigQuery.

This repository currently implements **Phase 1: the data lake** — a synthetic
telemetry generator that writes date-partitioned Parquet to a local data-lake layout
(mirroring the GCS structure), with an optional GCS upload.

## Telemetry schema

```
vehicle_id, timestamp, latitude, longitude, battery_soc, battery_voltage,
battery_temperature, motor_temperature, speed, odometer, charging_status,
power_consumption
```

Defined once in `src/ev_fleet/schema.py` and reused by the generator and writer.

## Project layout

```
src/ev_fleet/
  schema.py            # TelemetryRecord dataclass + PyArrow schema (single source of truth)
  generator/
    config.py          # GeneratorConfig: validated, reproducible run parameters
    telemetry.py       # per-vehicle state machine (DRIVING/CHARGING/IDLE) -> records
  lake/
    layout.py          # partitioned path layout: raw/telemetry/date=YYYY-MM-DD/
    writer.py          # local Parquet writer + optional GCS upload
  cli/
    generate.py        # `ev-generate` command wiring generator -> writer
tests/
  test_pipeline.py     # offline tests: determinism, plausibility, partitioned output
```

## Install

```bash
python -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"          # core + dev tooling
# For GCS upload support:
pip install -e ".[gcs,dev]"
```

Or with plain pip:

```bash
pip install -r requirements.txt
```

## Usage

Generate the default small dataset (100 vehicles, 1 day, 1 reading/minute) into a
local lake:

```bash
ev-generate --output data/lake
```

Smaller, faster run:

```bash
ev-generate --vehicles 10 --days 1 --interval 300 --output data/lake
```

This produces:

```
data/lake/raw/telemetry/date=2026-09-15/part-00000.parquet
data/lake/raw/telemetry/date=2026-09-15/part-00001.parquet
...
```

### Optional: upload to GCS

Requires the `gcs` extra and Application Default Credentials
(`gcloud auth application-default login`):

```bash
ev-generate --vehicles 10 --output data/lake --bucket my-ev-bucket --gcs-prefix ev-platform
```

## Data model notes

- Each vehicle is simulated as a state machine: SOC drains while **driving**, rises
  while **charging** (power consumption goes negative), and holds roughly steady
  while **idle**. Battery/motor temperatures track load. This makes downstream
  analytics and anomaly detection (later phases) meaningful rather than random noise.
- Output is partitioned by UTC calendar day using Hive-style `date=YYYY-MM-DD`
  directories, so BigQuery/Spark can auto-discover the `date` partition later.
- Generation is deterministic for a fixed `--seed`, and each vehicle has its own RNG
  derived from the seed so adding/removing vehicles does not perturb the others.

## Testing

```bash
pytest
```

## Roadmap

See the project plan for the full 7-phase roadmap (warehouse, streaming ingestion,
Dataflow/Beam, Dataproc/PySpark, BigQuery ML, orchestration, dashboard). Phase 1
(this repo) is the data-lake foundation.
