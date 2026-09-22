# outputs.tf — root module outputs
#
# These are the values a CI/CD pipeline, an operator, or another Terraform
# workspace might need to reference. Sensitive values are marked sensitive=true
# so Terraform masks them in plan/apply output.

# ---------------------------------------------------------------------------
# STORAGE
# ---------------------------------------------------------------------------

output "bucket_name" {
  description = "Name of the GCS data lake bucket."
  value       = module.storage.bucket_name
}

output "bucket_url" {
  description = "GCS URL of the data lake bucket (gs://...)."
  value       = module.storage.bucket_url
}

# ---------------------------------------------------------------------------
# BIGQUERY
# ---------------------------------------------------------------------------

output "ev_raw_dataset_id" {
  description = "BigQuery dataset ID for the raw landing zone (ev_raw)."
  value       = module.bigquery.ev_raw_dataset_id
}

output "ev_analytics_dataset_id" {
  description = "BigQuery dataset ID for the analytics/star-schema layer (ev_analytics)."
  value       = module.bigquery.ev_analytics_dataset_id
}

output "predictions_table_id" {
  description = "Fully qualified BigQuery table ID for ML predictions."
  value       = module.bigquery.predictions_table_id
}

# ---------------------------------------------------------------------------
# ARTIFACT REGISTRY + INGESTION
# ---------------------------------------------------------------------------

output "artifact_registry_url" {
  description = "Base URL for the Artifact Registry Docker repository (for docker push/pull)."
  value       = module.ingestion.artifact_registry_url
}

output "cloud_run_job_name" {
  description = "Name of the Cloud Run ingestion job."
  value       = module.ingestion.cloud_run_job_name
}

output "ingestion_scheduler_name" {
  description = "Name of the Cloud Scheduler job that triggers daily ingestion."
  value       = module.ingestion.scheduler_job_name
}

# ---------------------------------------------------------------------------
# WORKFLOWS
# ---------------------------------------------------------------------------

output "workflow_name" {
  description = "Name of the Cloud Workflows nightly pipeline."
  value       = module.workflows.workflow_name
}

output "workflow_id" {
  description = "Full resource ID of the Cloud Workflow."
  value       = module.workflows.workflow_id
}

output "pipeline_scheduler_name" {
  description = "Name of the Cloud Scheduler job that triggers the full pipeline."
  value       = module.workflows.pipeline_scheduler_name
}

# ---------------------------------------------------------------------------
# IAM
# ---------------------------------------------------------------------------

output "ingestion_sa_email" {
  description = "Email of the ingestion Cloud Run service account (ev-ingest-runner)."
  value       = module.iam.ingest_sa_email
}

output "workflow_sa_email" {
  description = "Email of the workflow orchestration service account (ev-workflow-runner)."
  value       = module.iam.workflow_sa_email
}

# ---------------------------------------------------------------------------
# PUB/SUB
# ---------------------------------------------------------------------------

output "pubsub_topic_id" {
  description = "Pub/Sub topic ID for real-time telemetry streaming."
  value       = module.pubsub.topic_id
}

output "pubsub_bq_subscription_id" {
  description = "Pub/Sub subscription ID for the native BigQuery subscription (Phase 4a)."
  value       = module.pubsub.bq_subscription_id
}

# ---------------------------------------------------------------------------
# MONITORING
# ---------------------------------------------------------------------------

output "monitoring_notification_channel_id" {
  description = "Cloud Monitoring notification channel ID (email alerts)."
  value       = module.monitoring.notification_channel_id
}

# ---------------------------------------------------------------------------
# STREAMING REFERENCES (non-managed; for CI scripts and runbooks)
# ---------------------------------------------------------------------------

output "dataflow_temp_location" {
  description = "GCS temp location for Dataflow jobs."
  value       = module.streaming.dataflow_temp_location
}

output "dataflow_subscription_path" {
  description = "Full Pub/Sub subscription path used by the Dataflow Beam pipeline."
  value       = module.streaming.dataflow_subscription_path
}

output "dataproc_spark_script_path" {
  description = "GCS path of the PySpark battery health script for Dataproc jobs."
  value       = module.streaming.dataproc_spark_script_gcs_path
}
