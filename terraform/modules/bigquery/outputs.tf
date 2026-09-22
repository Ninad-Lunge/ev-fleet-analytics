output "ev_raw_dataset_id" {
  description = "BigQuery dataset ID for the raw landing zone."
  value       = google_bigquery_dataset.ev_raw.dataset_id
}

output "ev_analytics_dataset_id" {
  description = "BigQuery dataset ID for the analytics layer."
  value       = google_bigquery_dataset.ev_analytics.dataset_id
}

output "telemetry_ext_table_id" {
  description = "Fully qualified table ID of the external telemetry table."
  value       = "${var.project_id}.${google_bigquery_dataset.ev_raw.dataset_id}.${google_bigquery_table.telemetry_ext.table_id}"
}

output "telemetry_table_id" {
  description = "Fully qualified table ID of the native telemetry table."
  value       = "${var.project_id}.${google_bigquery_dataset.ev_raw.dataset_id}.${google_bigquery_table.telemetry.table_id}"
}

output "predictions_table_id" {
  description = "Fully qualified table ID for ML predictions."
  value       = "${var.project_id}.${google_bigquery_dataset.ev_analytics.dataset_id}.${google_bigquery_table.predictions.table_id}"
}
