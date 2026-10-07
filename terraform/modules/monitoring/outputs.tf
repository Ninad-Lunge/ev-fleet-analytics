output "notification_channel_id" {
  description = "Cloud Monitoring notification channel ID."
  value       = google_monitoring_notification_channel.email.id
}

output "notification_channel_name" {
  description = "Display name of the notification channel."
  value       = google_monitoring_notification_channel.email.display_name
}

output "workflow_alert_id" {
  description = "Alert policy ID for workflow execution failures. Null until enabled post-deployment."
  value       = null
}

output "pubsub_alert_id" {
  description = "Alert policy ID for Pub/Sub subscription backlog."
  value       = google_monitoring_alert_policy.pubsub_backlog.id
}

output "data_quality_alert_id" {
  description = "Alert policy ID for telemetry ingestion gap. Null until enabled post-deployment."
  value       = null
}

output "cloud_run_alert_id" {
  description = "Alert policy ID for Cloud Run ingestion job failures."
  value       = google_monitoring_alert_policy.cloud_run_failure.id
}

output "telemetry_log_metric_id" {
  description = "Log-based metric ID used by the telemetry gap alert."
  value       = google_logging_metric.ev_telemetry_row_count.id
}
