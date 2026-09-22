output "notification_channel_id" {
  description = "Cloud Monitoring notification channel ID."
  value       = google_monitoring_notification_channel.email.id
}

output "notification_channel_name" {
  description = "Display name of the notification channel."
  value       = google_monitoring_notification_channel.email.display_name
}

output "workflow_alert_id" {
  description = "Alert policy ID for workflow execution failures."
  value       = google_monitoring_alert_policy.workflow_failed.id
}

output "pubsub_alert_id" {
  description = "Alert policy ID for Pub/Sub subscription backlog."
  value       = google_monitoring_alert_policy.pubsub_backlog.id
}

output "data_quality_alert_id" {
  description = "Alert policy ID for telemetry ingestion gap (data freshness)."
  value       = google_monitoring_alert_policy.telemetry_gap.id
}

output "cloud_run_alert_id" {
  description = "Alert policy ID for Cloud Run ingestion job failures."
  value       = google_monitoring_alert_policy.cloud_run_failure.id
}
