"""Publish EV telemetry records to a Pub/Sub topic.

Design:
    * The generator is reused unchanged as the event source; this module only adds
      serialization + publishing, keeping generation and transport separate.
    * The Pub/Sub client is accessed behind a small ``Publisher`` protocol so the
      publish loop can be unit-tested offline with a fake, without google-cloud-pubsub
      installed.
    * A JSON message body is used because it is human-readable in the Pub/Sub console
      and is directly compatible with a Pub/Sub -> BigQuery subscription.
"""

from __future__ import annotations

import json
import time
from collections.abc import Iterable, Iterator
from typing import Protocol

from ev_fleet.schema import TelemetryRecord


def record_to_json(record: TelemetryRecord) -> bytes:
    """Serialize a telemetry record to UTF-8 JSON bytes (Pub/Sub message body).

    The timestamp is emitted as an ISO-8601 string so it maps cleanly to a BigQuery
    TIMESTAMP column when a Pub/Sub -> BigQuery subscription writes the message.
    """
    payload = record.to_dict()
    payload["timestamp"] = record.timestamp.isoformat()
    return json.dumps(payload).encode("utf-8")


class Publisher(Protocol):
    """Minimal publish interface (subset of the Pub/Sub PublisherClient)."""

    def publish(self, topic: str, data: bytes) -> object:  # pragma: no cover
        ...


def publish_stream(
    records: Iterable[TelemetryRecord],
    publisher: Publisher,
    topic_path: str,
    *,
    rate_per_second: float = 10.0,
    limit: int | None = None,
) -> int:
    """Publish records to a topic at an approximate fixed rate.

    Args:
        records: Source stream of telemetry records (e.g. from ``generate_records``).
        publisher: A Pub/Sub-like publisher (real client or a test fake).
        topic_path: Fully-qualified topic, e.g.
            ``projects/<proj>/topics/ev-telemetry``.
        rate_per_second: Target publish rate; used to pace the loop so a simulator
            does not blast the whole day of data instantly.
        limit: Optional cap on the number of messages to publish (useful for a
            short, bounded test run).

    Returns:
        The number of messages published.
    """
    interval = 1.0 / rate_per_second if rate_per_second > 0 else 0.0
    published = 0

    for record in _capped(records, limit):
        publisher.publish(topic_path, record_to_json(record))
        published += 1
        if interval:
            time.sleep(interval)

    return published


def _capped(records: Iterable[TelemetryRecord], limit: int | None) -> Iterator[TelemetryRecord]:
    """Yield at most ``limit`` records (or all of them when ``limit`` is None)."""
    if limit is None:
        yield from records
        return
    for i, record in enumerate(records):
        if i >= limit:
            return
        yield record
