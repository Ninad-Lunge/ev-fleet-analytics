"""Synthetic EV telemetry generation.

Public API:
    GeneratorConfig    - tunable parameters for a generation run
    generate_records   - yield TelemetryRecord objects for the configured fleet/window
"""

from ev_fleet.generator.config import GeneratorConfig
from ev_fleet.generator.telemetry import generate_records

__all__ = ["GeneratorConfig", "generate_records"]
