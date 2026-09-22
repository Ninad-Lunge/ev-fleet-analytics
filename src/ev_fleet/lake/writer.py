"""Data-lake writers: local Parquet and optional GCS upload.

The writer consumes a stream of :class:`TelemetryRecord` objects and groups them by
UTC calendar day, writing one Parquet file per (day) partition. Grouping happens in a
streaming fashion: records for a day are buffered, and a partition is flushed as soon
as a record for a later day is seen. This keeps memory bounded to roughly one day of
data at a time, which matters once runs grow to many vehicles/days.

GCS upload is optional and imported lazily, so the package works fully offline unless
the ``gcs`` extra is installed and an upload is explicitly requested.
"""

from __future__ import annotations

import os
from collections.abc import Iterable, Iterator
from datetime import date
from pathlib import Path

import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq

from ev_fleet.lake.layout import LakeLayout
from ev_fleet.schema import COLUMNS, TelemetryRecord, arrow_schema


def _records_to_table(records: list[TelemetryRecord]) -> pa.Table:
    """Convert a list of records into a PyArrow Table with the canonical schema."""
    # Build a DataFrame with a fixed column order, then cast to the explicit Arrow
    # schema so every partition file has identical, predictable types.
    frame = pd.DataFrame([r.to_dict() for r in records], columns=list(COLUMNS))
    return pa.Table.from_pandas(frame, schema=arrow_schema(), preserve_index=False)


def _group_by_day(
    records: Iterable[TelemetryRecord],
) -> Iterator[tuple[date, list[TelemetryRecord]]]:
    """Yield ``(day, records)`` batches, flushing when the calendar day changes.

    Assumes each vehicle's records are chronological (as the generator guarantees).
    Because the stream is grouped by vehicle then time, the same day can recur across
    vehicles; each contiguous run for a day is flushed independently, producing
    multiple part files per day, which is a normal and desirable data-lake pattern.
    """
    current_day: date | None = None
    buffer: list[TelemetryRecord] = []

    for record in records:
        day = record.timestamp.date()
        if current_day is None:
            current_day = day
        if day != current_day:
            yield current_day, buffer
            current_day = day
            buffer = []
        buffer.append(record)

    if buffer and current_day is not None:
        yield current_day, buffer


def write_local(
    records: Iterable[TelemetryRecord],
    layout: LakeLayout,
    *,
    compression: str = "snappy",
) -> list[Path]:
    """Write records to the local filesystem as date-partitioned Parquet.

    Args:
        records: Stream of telemetry records (typically from ``generate_records``).
        layout: Lake layout describing the partitioned path structure.
        compression: Parquet compression codec (``snappy`` is a good default).

    Returns:
        The list of Parquet file paths written, in write order.
    """
    written: list[Path] = []
    # A monotonically increasing counter guarantees unique part-file names even when
    # a day is flushed multiple times (once per vehicle run).
    part_index = 0

    for day, batch in _group_by_day(records):
        partition_dir = Path(layout.partition_prefix(day))
        partition_dir.mkdir(parents=True, exist_ok=True)

        filename = f"part-{part_index:05d}.parquet"
        path = partition_dir / filename
        table = _records_to_table(batch)
        pq.write_table(table, path, compression=compression)

        written.append(path)
        part_index += 1

    return written


def upload_to_gcs(
    local_root: str | Path,
    bucket_name: str,
    *,
    prefix: str = "",
) -> int:
    """Upload a local lake tree to a GCS bucket, preserving relative paths.

    This is optional and only used when the user explicitly requests an upload. It
    requires the ``gcs`` extra (``pip install -e ".[gcs]"``) and valid Application
    Default Credentials (e.g. ``gcloud auth application-default login``).

    Args:
        local_root: Local directory whose contents should be uploaded.
        bucket_name: Target GCS bucket name (without ``gs://``).
        prefix: Optional object-name prefix within the bucket.

    Returns:
        The number of files uploaded.

    Raises:
        ImportError: If the optional google-cloud-storage dependency is missing.
    """
    try:
        from google.cloud import storage  # imported lazily; optional dependency
    except ImportError as exc:  # pragma: no cover - exercised only without the extra
        raise ImportError(
            "google-cloud-storage is required for GCS upload. "
            'Install it with: pip install -e ".[gcs]"'
        ) from exc

    local_root = Path(local_root)
    client = storage.Client()
    bucket = client.bucket(bucket_name)

    uploaded = 0
    for file_path in sorted(local_root.rglob("*.parquet")):
        # Preserve the directory structure relative to local_root as the object name.
        relative = file_path.relative_to(local_root).as_posix()
        object_name = f"{prefix.rstrip('/')}/{relative}" if prefix else relative
        bucket.blob(object_name).upload_from_filename(os.fspath(file_path))
        uploaded += 1

    return uploaded
