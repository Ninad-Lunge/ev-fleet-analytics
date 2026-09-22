output "ingest_sa_email" {
  description = "Email of the ingestion service account (ev-ingest-runner)."
  value       = google_service_account.ingest_runner.email
}

output "ingest_sa_id" {
  description = "Unique ID of the ingestion service account."
  value       = google_service_account.ingest_runner.unique_id
}

output "workflow_sa_email" {
  description = "Email of the workflow orchestration service account (ev-workflow-runner)."
  value       = google_service_account.workflow_runner.email
}

output "workflow_sa_id" {
  description = "Unique ID of the workflow service account."
  value       = google_service_account.workflow_runner.unique_id
}
