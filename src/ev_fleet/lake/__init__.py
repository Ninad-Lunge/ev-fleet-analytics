"""Data-lake layout and writers.

Public API:
    LakeLayout      - builds partitioned object paths (raw/telemetry/date=.../...)
    write_local     - write records to the local filesystem as partitioned Parquet
    upload_to_gcs   - optional upload of a local lake tree to a GCS bucket
"""

from ev_fleet.lake.layout import LakeLayout
from ev_fleet.lake.writer import upload_to_gcs, write_local

__all__ = ["LakeLayout", "write_local", "upload_to_gcs"]
