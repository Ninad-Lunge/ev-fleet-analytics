output "topic_id" {
  description = "Pub/Sub topic ID."
  value       = google_pubsub_topic.ev_telemetry.id
}

output "topic_name" {
  description = "Pub/Sub topic name (short form)."
  value       = google_pubsub_topic.ev_telemetry.name
}

output "bq_subscription_id" {
  description = "Pub/Sub BigQuery subscription ID (Phase 4a)."
  value       = google_pubsub_subscription.ev_telemetry_bq.id
}

output "beam_subscription_id" {
  description = "Pub/Sub pull subscription ID for the Dataflow Beam pipeline (Phase 4b)."
  value       = google_pubsub_subscription.ev_telemetry_beam.id
}
