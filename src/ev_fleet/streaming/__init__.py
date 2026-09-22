"""Streaming publisher for EV telemetry (Phase 4).

Public API:
    record_to_json     - serialize a TelemetryRecord to JSON bytes for Pub/Sub
    publish_stream      - publish a live stream of records to a Pub/Sub topic
"""

from ev_fleet.streaming.publisher import publish_stream, record_to_json

__all__ = ["publish_stream", "record_to_json"]
