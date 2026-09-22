variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "GCP region for Artifact Registry, Cloud Run, and Cloud Scheduler."
  type        = string
}

variable "bucket_name" {
  description = "GCS bucket name for the data lake. Passed as the --bucket arg to the container."
  type        = string
}

variable "container_image" {
  description = "Full container image URI including tag (e.g. asia-south1-docker.pkg.dev/.../ev-generator:v1)."
  type        = string
}

variable "ingest_sa_email" {
  description = "Email of the ingestion service account (ev-ingest-runner). The Cloud Run job runs as this identity."
  type        = string
}

variable "ingestion_cron" {
  description = "Cron expression for the ingestion Cloud Scheduler job."
  type        = string
  default     = "0 1 * * *"
}

variable "scheduler_timezone" {
  description = "IANA timezone for the Cloud Scheduler job."
  type        = string
  default     = "Asia/Kolkata"
}

variable "vehicles_per_run" {
  description = "Number of simulated vehicles per ingestion run."
  type        = number
  default     = 100
}

variable "interval_seconds" {
  description = "Telemetry sampling interval in seconds."
  type        = number
  default     = 300
}

variable "environment" {
  description = "Deployment environment label."
  type        = string
  default     = "dev"
}
