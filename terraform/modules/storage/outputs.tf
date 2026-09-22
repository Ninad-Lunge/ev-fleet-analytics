output "bucket_name" {
  description = "Name of the GCS data lake bucket."
  value       = google_storage_bucket.data_lake.name
}

output "bucket_url" {
  description = "GCS URL of the data lake bucket."
  value       = "gs://${google_storage_bucket.data_lake.name}"
}

output "bucket_self_link" {
  description = "Self-link URI of the GCS bucket (for IAM binding references)."
  value       = google_storage_bucket.data_lake.self_link
}
