"""``ev-generate`` command: generate synthetic telemetry into the data lake.

This is a thin orchestration layer:
    1. Parse CLI arguments into a validated ``GeneratorConfig``.
    2. Stream records from the generator into the local Parquet writer.
    3. Optionally upload the resulting lake tree to a GCS bucket.

Example:
    ev-generate --vehicles 100 --days 1 --interval 60 --output data/lake
    ev-generate --vehicles 10 --days 2 --output data/lake --bucket my-ev-bucket
"""

from __future__ import annotations

import argparse
import sys
from datetime import date, datetime, timezone

from ev_fleet.generator import GeneratorConfig, generate_records
from ev_fleet.lake import LakeLayout, upload_to_gcs, write_local


def _parse_date(value: str) -> date:
    """Parse a ``YYYY-MM-DD`` string into a ``date`` for argparse."""
    try:
        return datetime.strptime(value, "%Y-%m-%d").date()
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid date '{value}', expected YYYY-MM-DD") from exc


def _build_parser() -> argparse.ArgumentParser:
    """Construct the argument parser for the generate command."""
    parser = argparse.ArgumentParser(
        prog="ev-generate",
        description="Generate synthetic EV telemetry into a date-partitioned data lake.",
    )
    parser.add_argument(
        "--vehicles", type=int, default=100, help="number of vehicles (default: 100)"
    )
    parser.add_argument(
        "--days", type=int, default=1, help="number of consecutive days (default: 1)"
    )
    parser.add_argument(
        "--interval",
        type=int,
        default=60,
        help="seconds between readings; must divide 86400 (default: 60)",
    )
    parser.add_argument(
        "--start-date",
        type=_parse_date,
        default=date(2026, 9, 15),
        help="first UTC day to generate, YYYY-MM-DD (default: 2026-09-15)",
    )
    parser.add_argument(
        "--today",
        action="store_true",
        help="ignore --start-date and generate for the current UTC date; intended for "
        "scheduled runs (e.g. Cloud Run + Cloud Scheduler) so each run lands a fresh "
        "date=<today> partition",
    )
    parser.add_argument(
        "--seed", type=int, default=42, help="RNG seed for reproducibility (default: 42)"
    )
    parser.add_argument(
        "--output",
        default="data/lake",
        help="local lake root directory (default: data/lake)",
    )
    parser.add_argument(
        "--bucket",
        default=None,
        help="optional GCS bucket name to upload the lake tree to (requires the gcs extra)",
    )
    parser.add_argument(
        "--gcs-prefix",
        default="",
        help="optional object-name prefix within the GCS bucket",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint. Returns a process exit code (0 = success)."""
    parser = _build_parser()
    args = parser.parse_args(argv)

    # Build and validate the run configuration. Validation errors surface as a clean
    # message and a non-zero exit code rather than a traceback.
    # A scheduled run uses --today so each run lands a fresh date=<today> partition;
    # otherwise honour the explicit --start-date.
    start_date = datetime.now(timezone.utc).date() if args.today else args.start_date

    try:
        config = GeneratorConfig(
            num_vehicles=args.vehicles,
            start_date=start_date,
            num_days=args.days,
            interval_seconds=args.interval,
            seed=args.seed,
        )
    except ValueError as exc:
        parser.error(str(exc))

    layout = LakeLayout(root=args.output)

    print(
        f"Generating ~{config.total_records:,} records "
        f"({config.num_vehicles} vehicles x {config.num_days} day(s) "
        f"@ {config.interval_seconds}s) into '{args.output}' ...",
        file=sys.stderr,
    )

    # Stream records straight from the generator into the writer so memory stays low.
    written = write_local(generate_records(config), layout)
    print(f"Wrote {len(written)} Parquet file(s).", file=sys.stderr)

    if args.bucket:
        print(f"Uploading lake tree to gs://{args.bucket} ...", file=sys.stderr)
        count = upload_to_gcs(args.output, args.bucket, prefix=args.gcs_prefix)
        print(f"Uploaded {count} file(s) to gs://{args.bucket}.", file=sys.stderr)

    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
