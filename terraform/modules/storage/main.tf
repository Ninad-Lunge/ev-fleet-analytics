# modules/storage/main.tf
#
# GCS data lake bucket for the EV Fleet Analytics platform.
#
# Security posture:
#   - uniform_bucket_level_access: disables per-object ACLs. All access is
#     governed by IAM policies. Prevents the "I thought only I had access"
#     ACL footgun that has caused data breaches.
#   - public_access_prevention = "enforced": even a project-level change
#     granting allUsers access cannot make this bucket public. Belt and
#     braces for a data lake.
#   - versioning: enables object versioning for accidental-delete recovery.
#   - force_destroy = false: Terraform will refuse to delete the bucket if
#     it contains objects. This prevents `terraform destroy` from wiping
#     production data. Set to true only in non-prod environments where you
#     need clean teardown.

resource "google_storage_bucket" "data_lake" {
  project  = var.project_id
  name     = var.bucket_name
  location = var.location

  # Safety: refuse to delete a non-empty bucket.
  # Override to true in dev/staging via the root module if needed.
  force_destroy = false

  # All access governed by IAM, not per-object ACLs.
  uniform_bucket_level_access = true

  # Cannot be made public even by project-level IAM grants.
  public_access_prevention = "enforced"

  # Enables point-in-time recovery of accidentally deleted or overwritten objects.
  versioning {
    enabled = true
  }

  # ---------------------------------------------------------------------------
  # Lifecycle rules — applied only to the raw/ prefix to avoid tiering
  # curated/processed data that is actively queried.
  # ---------------------------------------------------------------------------

  # Tier 1 → NEARLINE after n days: infrequently accessed but retrievable
  # within milliseconds. ~50% cheaper than STANDARD.
  lifecycle_rule {
    condition {
      age             = var.lifecycle_age_days_to_nearline
      matches_prefix  = ["raw/"]
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  # Tier 2 → COLDLINE after n days: accessed < once per quarter.
  # ~75% cheaper than STANDARD; retrieval has a per-GB cost.
  lifecycle_rule {
    condition {
      age             = var.lifecycle_age_days_to_coldline
      matches_prefix  = ["raw/"]
    }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }

  # Tier 3 → Delete after n days: raw data beyond the retention window.
  # Curated/analytics copies should be kept in BigQuery; raw files expire.
  lifecycle_rule {
    condition {
      age            = var.lifecycle_age_days_to_delete
      matches_prefix = ["raw/"]
    }
    action {
      type = "Delete"
    }
  }

  labels = merge(var.tags, {
    environment = var.environment
    managed-by  = "terraform"
    purpose     = "data-lake"
  })
}

# ---------------------------------------------------------------------------
# Materialise the dataflow/staging/ prefix so Dataflow has a valid staging
# location without needing to create the prefix itself (some versions of the
# Dataflow SDK fail if the staging path does not already exist).
# This is a zero-byte placeholder object; it carries no data.
# ---------------------------------------------------------------------------
resource "google_storage_bucket_object" "dataflow_staging_placeholder" {
  bucket  = google_storage_bucket.data_lake.name
  name    = "dataflow/staging/.gitkeep"
  content = ""
}
