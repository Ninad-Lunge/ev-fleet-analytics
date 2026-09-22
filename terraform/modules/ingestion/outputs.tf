output "artifact_registry_id" {
  description = "Artifact Registry repository ID."
  value       = google_artifact_registry_repository.ev_fleet.id
}

output "artifact_registry_url" {
  description = "Base URL for the Artifact Registry Docker repository."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.ev_fleet.repository_id}"
}

output "cloud_run_job_name" {
  description = "Name of the Cloud Run ingestion job."
  value       = google_cloud_run_v2_job.ev_generator.name
}

output "cloud_run_job_id" {
  description = "Full resource ID of the Cloud Run job."
  value       = google_cloud_run_v2_job.ev_generator.id
}

output "scheduler_job_name" {
  description = "Name of the Cloud Scheduler ingestion trigger."
  value       = google_cloud_scheduler_job.ev_ingest_daily.name
}
