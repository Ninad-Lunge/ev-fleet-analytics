variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "project_number" {
  description = "Numeric GCP project number. Used to construct service-agent email addresses."
  type        = string
}

variable "region" {
  description = "GCP region (needed for Cloud Run job IAM resource path)."
  type        = string
}

variable "bucket_name" {
  description = "GCS bucket name for bucket-level IAM bindings."
  type        = string
}

variable "cloud_run_job_name" {
  description = "Cloud Run Job name for the run.invoker resource-level binding."
  type        = string
}

variable "pubsub_service_agent" {
  description = "Pub/Sub service agent email (service-<project_number>@gcp-sa-pubsub.iam.gserviceaccount.com)."
  type        = string
}

variable "compute_default_sa" {
  description = "Compute Engine default SA email (<project_number>-compute@developer.gserviceaccount.com)."
  type        = string
}
