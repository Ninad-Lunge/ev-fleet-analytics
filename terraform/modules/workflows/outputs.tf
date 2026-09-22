output "workflow_name" {
  description = "Name of the Cloud Workflow."
  value       = google_workflows_workflow.ev_nightly_pipeline.name
}

output "workflow_id" {
  description = "Full resource ID of the Cloud Workflow."
  value       = google_workflows_workflow.ev_nightly_pipeline.id
}

output "workflow_revision_id" {
  description = "Revision ID of the deployed workflow (changes on every YAML update)."
  value       = google_workflows_workflow.ev_nightly_pipeline.revision_id
}

output "pipeline_scheduler_name" {
  description = "Name of the Cloud Scheduler job that triggers the pipeline."
  value       = google_cloud_scheduler_job.ev_pipeline_daily.name
}
