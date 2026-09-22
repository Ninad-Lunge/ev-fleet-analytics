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

resource "google_monitoring_alert_policy" "workflow_failed" {
  project      = var.project_id
  display_name = "[EV] Workflow Execution Failed (${var.environment})"
  enabled      = true
  combiner     = "OR"

  conditions {
    display_name = "ev-nightly-pipeline execution failed"

    condition_threshold {
      # Count of finished workflow executions with status=FAILED.
      filter          = "resource.type=\"workflows.googleapis.com/Workflow\" AND metric.type=\"workflowexecutions.googleapis.com/finished_execution_count\" AND metric.labels.status=\"FAILED\" AND resource.labels.workflow_id=\"${var.workflow_name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s" # alert immediately — do not wait for a sustained condition

      aggregations {
        alignment_period     = "3600s" # 1-hour window
        per_series_aligner   = "ALIGN_COUNT"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.label.workflow_id"]
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]

  documentation {
    subject = "[EV] Nightly pipeline failed — ${var.workflow_name}"
    content = <<-EOT
      The Cloud Workflow **${var.workflow_name}** reported a FAILED execution.

      Investigate:
      1. Open Cloud Workflows console → select the failed execution.
      2. Check which step failed (warehouse refresh, enrichment, ML, or predictions).
      3. Check BigQuery job history for any failed BQ jobs within that execution.
      4. Re-run manually: gcloud workflows run ${var.workflow_name} --location=asia-south1
    EOT
  }
}

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
# PREREQUISITE: Create the log-based metric first:
#   gcloud logging metrics create ev_telemetry_row_count \
#     --description="Count of telemetry rows written per ingestion run" \
#     --log-filter='resource.type="cloud_run_job" AND resource.labels.job_name="ev-generator" AND textPayload:"Wrote"' \
#     --project=<PROJECT_ID>
#
# The metric counts log lines matching "Wrote N Parquet file(s)." from the
# ev-generator container. If no lines are counted for 25h, ingestion has
# silently stopped.
# =============================================================================

resource "google_monitoring_alert_policy" "telemetry_gap" {
  project      = var.project_id
  display_name = "[EV] Data Quality — Telemetry Ingestion Gap > 25h (${var.environment})"
  enabled      = true
  combiner     = "OR"

  conditions {
    display_name = "No telemetry ingestion for 25 hours"

    condition_threshold {
      # Custom log-based metric — requires the gcloud command in the comment above.
      filter          = "resource.type=\"global\" AND metric.type=\"logging.googleapis.com/user/ev_telemetry_row_count\""
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "90000s" # 25 hours — allows for a 1-hour window around the scheduled run

      aggregations {
        alignment_period     = "3600s"
        per_series_aligner   = "ALIGN_COUNT"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]

  documentation {
    subject = "[EV] ALERT: No telemetry rows ingested in 25 hours"
    content = <<-EOT
      No telemetry ingestion activity has been detected in the last 25 hours.
      This could mean: the Cloud Run job did not run, the generator produced zero rows,
      or the log-based metric is not receiving events.

      Investigate:
      1. Check Cloud Scheduler: was ev-ingest-daily triggered today?
      2. Check Cloud Run job history: did ev-generator complete successfully?
      3. Check GCS: does gs://${var.project_id}/raw/telemetry/date=today/ exist?
      4. Check the custom metric: gcloud logging metrics list --project=${var.project_id}
    EOT
  }
}

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
