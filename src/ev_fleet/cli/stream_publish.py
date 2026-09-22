"""``ev-stream-publish`` command: stream synthetic telemetry to a Pub/Sub topic.

Reuses the generator as the event source and publishes each record as a JSON
message to Pub/Sub, pacing the output to simulate a live fleet.

Example:
    ev-stream-publish --project my-proj --topic ev-telemetry \
        --vehicles 20 --rate 20 --limit 500

The --limit flag makes a bounded test run (publish N messages then stop), which is
the recommended way to test without leaving a publisher running.
"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone

from ev_fleet.generator import GeneratorConfig, generate_records
from ev_fleet.streaming import publish_stream


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="ev-stream-publish",
        description="Publish synthetic EV telemetry to a Pub/Sub topic (streaming simulator).",
    )
    parser.add_argument("--project", required=True, help="GCP project id")
    parser.add_argument("--topic", default="ev-telemetry", help="Pub/Sub topic id")
    parser.add_argument("--vehicles", type=int, default=20, help="number of vehicles")
    parser.add_argument(
        "--interval", type=int, default=60, help="seconds between readings per vehicle"
    )
    parser.add_argument(
        "--rate", type=float, default=20.0, help="messages published per second (pacing)"
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=500,
        help="stop after publishing this many messages (bounded test run)",
    )
    parser.add_argument("--seed", type=int, default=42, help="RNG seed")
    return parser


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint. Returns a process exit code (0 = success)."""
    parser = _build_parser()
    args = parser.parse_args(argv)

    # Import the Pub/Sub client lazily so the module imports without the extra.
    try:
        from google.cloud import pubsub_v1
    except ImportError:
        parser.error(
            'google-cloud-pubsub is required. Install it with: pip install -e ".[pubsub]"'
        )

    config = GeneratorConfig(
        num_vehicles=args.vehicles,
        start_date=datetime.now(timezone.utc).date(),
        num_days=1,
        interval_seconds=args.interval,
        seed=args.seed,
    )

    client = pubsub_v1.PublisherClient()
    topic_path = client.topic_path(args.project, args.topic)

    print(
        f"Publishing up to {args.limit} messages to {topic_path} "
        f"at ~{args.rate}/s ...",
        file=sys.stderr,
    )
    count = publish_stream(
        generate_records(config),
        client,
        topic_path,
        rate_per_second=args.rate,
        limit=args.limit,
    )
    print(f"Published {count} messages.", file=sys.stderr)
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
