"""Offline tests for the streaming publisher (no Pub/Sub required)."""

from __future__ import annotations

import json

from ev_fleet.generator import GeneratorConfig, generate_records
from ev_fleet.streaming import publish_stream, record_to_json
from ev_fleet.streaming.publisher import Publisher


class FakePublisher(Publisher):
    """Captures published messages instead of sending them to Pub/Sub."""

    def __init__(self) -> None:
        self.messages: list[bytes] = []

    def publish(self, topic: str, data: bytes) -> object:
        self.messages.append(data)
        return object()


def test_record_to_json_roundtrip() -> None:
    config = GeneratorConfig(num_vehicles=1, num_days=1, interval_seconds=3600)
    record = next(generate_records(config))
    payload = json.loads(record_to_json(record))
    assert payload["vehicle_id"] == record.vehicle_id
    # Timestamp is serialized as an ISO-8601 string.
    assert isinstance(payload["timestamp"], str)
    assert "T" in payload["timestamp"]


def test_publish_stream_respects_limit() -> None:
    config = GeneratorConfig(num_vehicles=5, num_days=1, interval_seconds=60)
    pub = FakePublisher()
    # rate_per_second=0 disables sleeping so the test is instant.
    count = publish_stream(
        generate_records(config), pub, "projects/x/topics/t", rate_per_second=0, limit=50
    )
    assert count == 50
    assert len(pub.messages) == 50
    # Every message is valid JSON with the expected keys.
    first = json.loads(pub.messages[0])
    assert {"vehicle_id", "timestamp", "battery_soc"} <= first.keys()
