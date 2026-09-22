"""Data-lake path layout.

Centralises how objects are laid out in the lake so the local writer and the GCS
uploader agree on structure. The layout mirrors the Phase 1 plan:

    <root>/raw/telemetry/date=YYYY-MM-DD/<filename>.parquet

Using Hive-style ``date=YYYY-MM-DD`` partition directories means BigQuery (and
Spark) can later discover the ``date`` partition column automatically when the tree
is pointed at as an external table.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date


@dataclass(frozen=True, slots=True)
class LakeLayout:
    """Builds partitioned paths within a data lake rooted at ``root``.

    ``root`` is a prefix only; it may be a local directory (e.g. ``data/lake``) or a
    GCS object prefix (e.g. ``ev-platform``). Path components use forward slashes so
    the same layout is valid for both local POSIX paths and GCS object names.

    Attributes:
        root: Lake root prefix, without a trailing slash.
        zone: Lake zone; defaults to ``raw`` for freshly ingested data.
        dataset: Logical dataset name; defaults to ``telemetry``.
    """

    root: str = "data/lake"
    zone: str = "raw"
    dataset: str = "telemetry"

    def partition_prefix(self, day: date) -> str:
        """Return the partition directory for a given day (no trailing slash)."""
        return f"{self.root}/{self.zone}/{self.dataset}/date={day.isoformat()}"

    def object_path(self, day: date, filename: str) -> str:
        """Return the full object path for ``filename`` within ``day``'s partition."""
        return f"{self.partition_prefix(day)}/{filename}"
