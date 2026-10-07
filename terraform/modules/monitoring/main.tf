# modules/monitoring/main.tf
#
# Cloud Monitoring notification channel and alert policies for the EV Fleet
# Analytics platform. Covers:
#   1. Pipeline failure  — the Cloud Workflow execution failed
#   2. Data backlog      — Pub/Sub BQ subscription not draining (data quality)
#   3. Ingestion gap     — no new telemetry rows for 25 hours (data quality)
#   4. Cloud Run failure — the ingestion job's task failed
#
# Data quality philosophy: a pipeline that silently produces no data is worse
# than one that loudly fails. Alerts 3 and 4 detect silent failures (the job
# "succeeds" but writes nothing, or the job never ran).

# =============================================================================
# NOTIFICATION CHANNEL
# =============================================================================

resource "google_monitoring_notification_channel" "email" {
  project      = var.project_id
  type         = "email"
  display_name = "EV Platform Alerts (${var.environment})"

  labels = {
    email_address = var.alert_email
  }
}

# =============================================================================
# ALERT 1: Cloud Workflow execution failed
# This fires when the nightly pipeline DAG itself returns an error state.
# Check the Workflow execution logs in GCP console for the exact failing step.
# =============================================================================

# =============================================================================
# ALERT 1: Cloud Workflow execution failed
# NOTE: This alert cannot be created until the workflow has executed at least
# once, because the workflowexecutions.googleapis.com metric descriptor is
# only registered by Cloud Monitoring after first execution (~10 min).
#
# TO ENABLE: After running `gcloud workflows run ev-nightly-pipeline` once
# successfully, uncomment this resource and run `terraform apply`.
# =============================================================================

# resource "google_monitoring_alert_policy" "workflow_failed" {
#   project      = var.project_id
#   display_name = "[EV] Workflow Execution Failed (${var.environment})"
#   enabled      = true
#   combiner     = "OR"
#
#   conditions {
#     display_name = "ev-nightly-pipeline execution failed"
#     condition_threshold {
#       filter          = "resource.type=\"workflows.googleapis.com/Workflow\" AND metric.type=\"workflowexecutions.googleapis.com/finished_execution_count\" AND metric.labels.status=\"FAILED\" AND resource.labels.workflow_id=\"${var.workflow_name}\""
#       comparison      = "COMPARISON_GT"
#       threshold_value = 0
#       duration        = "0s"
#       aggregations {
#         alignment_period     = "3600s"
#         per_series_aligner   = "ALIGN_COUNT"
#         cross_series_reducer = "REDUCE_SUM"
#         group_by_fields      = ["resource.label.workflow_id"]
#       }
#     }
#   }
#   notification_channels = [google_monitoring_notification_channel.email.id]
# }

# =============================================================================
# ALERT 2: Pub/Sub backlog high — data quality signal
# If ev-telemetry-bq has > N undelivered messages, the BigQuery subscription
# is not draining. Possible causes: BQ table schema mismatch, permissions issue,
# or the BQ streaming API is throttled.
# This is a DATA QUALITY alert: data is being produced but not landing.
# =============================================================================

resource "google_monitoring_alert_policy" "pubsub_backlog" {
  project      = var.project_id
  display_name = "[EV] Pub/Sub BQ Subscription Backlog High (${var.environment})"
  enabled      = true
  combiner     = "OR"

  conditions {
    display_name = "ev-telemetry-bq undelivered messages > ${var.pubsub_subscription_backlog_threshold}"

    condition_threshold {
      filter          = "resource.type=\"pubsub_subscription\" AND metric.type=\"pubsub.googleapis.com/subscription/num_undelivered_messages\" AND resource.labels.subscription_id=\"ev-telemetry-bq\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.pubsub_subscription_backlog_threshold
      duration        = "300s" # sustained for 5 minutes before alerting

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]

  documentation {
    subject = "[EV] Pub/Sub backlog — ev-telemetry-bq is not draining"
    content = <<-EOT
      The ev-telemetry-bq BigQuery subscription has accumulated > ${var.pubsub_subscription_backlog_threshold} undelivered messages.
      Real-time data is NOT landing in ev_raw.telemetry_stream.

      Investigate:
      1. Check the subscription dead-letter / error messages in the GCP console.
      2. Verify the Pub/Sub service agent has roles/bigquery.dataEditor.
      3. Check for schema mismatches between the Pub/Sub message JSON and the BQ table schema.
      4. Check BigQuery API quota in Cloud Monitoring.
    EOT
  }
}

# =============================================================================
# ALERT 3: Telemetry ingestion gap — data quality / freshness signal
# Fires when the custom log-based metric ev_telemetry_row_count drops to zero
# for more than 25 hours. This detects: the Cloud Run job didn't run, the
# Parquet write succeeded but the warehouse refresh failed, or the ingestion
# produced zero rows (bad generator config).
#
# The log-based metric is created here as a Terraform resource so it exists
# on every fresh project deployment. The metric counts log lines from the
# ev-generator container matching "Wrote N Parquet file(s)."
# =============================================================================

resource "google_logging_metric" "ev_telemetry_row_count" {
  project     = var.project_id
  name        = "ev_telemetry_row_count"
  description = "Counts log lines from ev-generator confirming Parquet files were written. Used by the telemetry-gap alert to detect missed ingestion runs."
  filter      = "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"${var.cloud_run_job_name}\" AND textPayload=~\"Wrote [0-9]+ Parquet\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# =============================================================================
# ALERT 3: Telemetry ingestion gap
# NOTE: Cannot be created until the log-based metric has received at least one
# matching log entry. Cloud Monitoring rejects alerts with filters that return
# no time series on a fresh project.
#
# TO ENABLE: After the first successful ingestion run, uncomment and apply.
# =============================================================================

# resource "google_monitoring_alert_policy" "telemetry_gap" { ... }
# (see git history for full resource definition)

# =============================================================================
# ALERT 4: Cloud Run job task failure
# Fires when the ev-generator Cloud Run Job reports a failed task attempt.
# This is distinct from the workflow failure alert — the ingestion job runs
# independently at 01:00 IST before the workflow fires at 02:00 IST.
# =============================================================================

resource "google_monitoring_alert_policy" "cloud_run_failure" {
  project      = var.project_id
  display_name = "[EV] Cloud Run Ingestion Job Failed (${var.environment})"
  enabled      = true
  combiner     = "OR"

  conditions {
    display_name = "ev-generator task attempt failed"

    condition_threshold {
      filter          = "resource.type=\"cloud_run_job\" AND metric.type=\"run.googleapis.com/job/completed_task_attempt_count\" AND metric.labels.result=\"failed\" AND resource.labels.job_name=\"${var.cloud_run_job_name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s" # alert immediately on any failure

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_COUNT"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.label.job_name"]
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]

  documentation {
    subject = "[EV] Cloud Run job ev-generator failed"
    content = <<-EOT
      The Cloud Run job **${var.cloud_run_job_name}** reported a failed task attempt.
      Today's telemetry partition may be missing or incomplete.

      Investigate:
      1. Check Cloud Run → Jobs → ev-generator → Executions for the error.
      2. Check Cloud Logging for the container's stderr output.
      3. Manually trigger the job:
         gcloud run jobs execute ${var.cloud_run_job_name} --region=asia-south1
      4. Check GCS for the expected partition: gs://<BUCKET>/raw/telemetry/date=today/
    EOT
  }
}
