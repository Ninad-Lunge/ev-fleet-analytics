"""Phase 4b - Apache Beam streaming pipeline (runs on Dataflow).

Reads EV telemetry JSON from a Pub/Sub subscription, validates and parses each
message, enriches it with anomaly flags, and writes enriched records to BigQuery.

KEY DESIGN DECISION - self-contained functions:
    All transform functions are fully self-contained (no module-level globals
    referenced). Threshold constants are embedded as default argument values.
    This is the correct Beam pattern: when dill serializes a function to send
    to remote workers, it captures default arguments as part of the function
    object itself, so the worker never needs to resolve module-level names.
    Referencing module globals causes NameError on workers when the staged
    module version differs from the local one.

Pipeline shape:
    Pub/Sub --> parse JSON --> drop invalid --> enrich/flag anomalies --> BigQuery

COST WARNING:
    Dataflow runs continuous worker VMs. DRAIN or CANCEL immediately after testing:
        gcloud dataflow jobs list --region asia-south1 --status active
        gcloud dataflow jobs drain <JOB_ID> --region asia-south1

Install (Python 3.12, macOS arm64):
    python3.12 -m venv .beam-venv
    .beam-venv/bin/pip install "setuptools<81" wheel
    .beam-venv/bin/pip install --no-build-isolation "apache-beam[gcp]==2.60.0"

Run (from dataflow/ directory):
    ../.beam-venv/bin/python telemetry_pipeline.py \\
      --runner=DataflowRunner \\
      --project=project-623b2045-f641-41e7-894 \\
      --region=asia-south1 \\
      --temp_location=gs://ev-fleet-lake-project-ninad/dataflow/temp \\
      --staging_location=gs://ev-fleet-lake-project-ninad/dataflow/staging \\
      --subscription=projects/project-623b2045-f641-41e7-894/subscriptions/ev-telemetry-beam \\
      --output_table=project-623b2045-f641-41e7-894:ev_raw.telemetry_enriched \\
      --num_workers=1 --max_num_workers=1 --machine_type=e2-small \\
      --job_name=ev-telemetry-enrich3
"""

from __future__ import annotations

import argparse
import json
import logging
from datetime import datetime, timezone
from typing import Any

import apache_beam as beam
from apache_beam.options.pipeline_options import PipelineOptions, StandardOptions

# BigQuery output schema — must match ev_raw.telemetry_enriched exactly.
_BQ_SCHEMA = ",".join([
    "vehicle_id:STRING",
    "timestamp:TIMESTAMP",
    "battery_soc:FLOAT",
    "battery_temperature:FLOAT",
    "motor_temperature:FLOAT",
    "speed:FLOAT",
    "power_consumption:FLOAT",
    "charging_status:BOOLEAN",
    "is_anomaly:BOOLEAN",
    "anomaly_reason:STRING",
    "processed_at:TIMESTAMP",
])


def parse_message(raw: bytes) -> dict[str, Any] | None:
    """Parse Pub/Sub message bytes -> dict, or None for any invalid input.

    Fully self-contained: imports json inside the function so the worker never
    needs to resolve it as a module-level name during dill deserialization.
    """
    import json  # noqa: PLC0415 - intentionally inside function for Beam/dill safety
    try:
        record = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    if not isinstance(record, dict):
        return None
    if not record.get("vehicle_id") or not record.get("timestamp"):
        return None
    return record


def enrich(
    record: dict[str, Any],
    # Thresholds embedded as defaults so dill captures them inside the function
    # object itself. This is the correct Beam pattern for remote workers.
    battery_temp_max: float = 38.0,
    motor_temp_max: float = 70.0,
    low_soc_pct: float = 15.0,
) -> dict[str, Any]:
    """Add anomaly flags and processing metadata. Fully self-contained, no globals.

    ALL imports and constants are either default args or imported inside this
    function. This is required because dill serializes the function bytecode
    and sends it to remote workers; any global name reference (imports, module
    constants) resolves on the WORKER at runtime, not on the local machine.
    If the worker's staged module differs at all, those names are not found.
    The safest pattern: inline everything the function needs.
    """
    # Import inside the function so the worker never needs to resolve 'datetime'
    # as a module-level name. This is intentional, not a style oversight.
    from datetime import datetime, timezone  # noqa: PLC0415

    reasons: list[str] = []

    if record.get("battery_temperature", 0) > battery_temp_max:
        reasons.append("battery_temp_high")

    if record.get("motor_temperature", 0) > motor_temp_max:
        reasons.append("motor_temp_high")

    if (
        record.get("battery_soc", 100) < low_soc_pct
        and record.get("speed", 0) > 0
        and not record.get("charging_status", False)
    ):
        reasons.append("low_soc_while_driving")

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


def build_and_run(argv: list[str] | None = None) -> None:
    """Construct and run the streaming pipeline."""
    parser = argparse.ArgumentParser(description="EV telemetry Beam streaming pipeline")
    parser.add_argument("--subscription", required=True, help="Pub/Sub subscription path")
    parser.add_argument("--output_table", required=True,
                        help="BigQuery table, format project:dataset.table")
    known_args, pipeline_argv = parser.parse_known_args(argv)

    options = PipelineOptions(pipeline_argv)
    options.view_as(StandardOptions).streaming = True

    with beam.Pipeline(options=options) as pipeline:
        (
            pipeline
            | "ReadPubSub"    >> beam.io.ReadFromPubSub(subscription=known_args.subscription)
            | "Parse"         >> beam.Map(parse_message)
            | "DropInvalid"   >> beam.Filter(lambda r: r is not None)
            | "Enrich"        >> beam.Map(enrich)
            | "WriteBigQuery" >> beam.io.WriteToBigQuery(
                known_args.output_table,
                schema=_BQ_SCHEMA,
                write_disposition=beam.io.BigQueryDisposition.WRITE_APPEND,
                create_disposition=beam.io.BigQueryDisposition.CREATE_NEVER,
            )
        )


if __name__ == "__main__":
    logging.getLogger().setLevel(logging.INFO)
    build_and_run()
