# modules/pubsub/main.tf
#
# Pub/Sub topic and subscriptions for real-time telemetry streaming.
#
# Architecture:
#   ev-telemetry (topic)
#     ├── ev-telemetry-bq   (Phase 4a) — native BigQuery subscription, always-on
#     └── ev-telemetry-beam (Phase 4b) — pull subscription, consumed by Dataflow
#
# Each subscription gets an independent copy of every message published to the
# topic. Pub/Sub guarantees at-least-once delivery to each subscription.

# =============================================================================
# TOPIC
# =============================================================================

resource "google_pubsub_topic" "ev_telemetry" {
  project = var.project_id
  name    = "ev-telemetry"

  # Retain unacknowledged messages for 1 day. Messages published after all
  # subscriptions have been deleted are retained so a new subscription can
  # still receive them within this window.
  message_retention_duration = "86400s"

  labels = {
    environment = var.environment
    managed-by  = "terraform"
  }
}

# =============================================================================
# SUBSCRIPTION 4a — Pub/Sub → BigQuery (native, always-on)
# No Dataflow required. Pub/Sub writes JSON messages directly to the BQ table
# by matching JSON field names to column names (use_table_schema=true).
# drop_unknown_fields=true silently discards any extra JSON keys that don't
# map to schema columns — prevents the subscription from blocking on bad msgs.
# =============================================================================

resource "google_pubsub_subscription" "ev_telemetry_bq" {
  project = var.project_id
  name    = "ev-telemetry-bq"
  topic   = google_pubsub_topic.ev_telemetry.id

  # Write directly to BigQuery without a consumer process.
  bigquery_config {
    table             = "${var.project_id}:${var.bq_dataset_raw}.telemetry_stream"
    use_table_schema  = true   # map JSON fields to column names
    drop_unknown_fields = true # ignore extra JSON keys
  }

  ack_deadline_seconds = var.bq_ack_deadline_seconds

  # Never expire the subscription.
  expiration_policy {
    ttl = ""
  }

  # Retain undelivered messages for 1 day.
  message_retention_duration = "86400s"
}

# =============================================================================
# SUBSCRIPTION 4b — Pull subscription for Dataflow / Beam pipeline
# The Dataflow ev-telemetry-enrich4 job reads from this subscription.
# Dataflow is NOT always-on; this subscription accumulates messages until
# a Dataflow job is running. Launch Dataflow manually or via CI when needed.
# See the streaming module for the operational runbook.
# =============================================================================

resource "google_pubsub_subscription" "ev_telemetry_beam" {
  project = var.project_id
  name    = "ev-telemetry-beam"
  topic   = google_pubsub_topic.ev_telemetry.id

  # Pull subscription — no push_config needed.
  # Beam/Dataflow calls the Pull API to receive messages.
  ack_deadline_seconds = 600

  # Never expire the subscription so messages accumulate when Dataflow is off.
  expiration_policy {
    ttl = ""
  }

  message_retention_duration = "86400s"
}
