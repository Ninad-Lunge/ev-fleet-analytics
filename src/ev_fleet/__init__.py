"""EV Fleet Analytics - Phase 1 package.

Phase 1 scope: generate synthetic EV telemetry and land it in a date-partitioned
data-lake layout (local filesystem, with optional Google Cloud Storage upload).

Subpackages:
    generator - synthetic telemetry generation
    lake      - data-lake path layout and Parquet writing (local + GCS)
    cli       - command-line entrypoints
"""

__version__ = "0.1.0"
