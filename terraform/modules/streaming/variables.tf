variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "GCP region for streaming/batch jobs."
  type        = string
}

variable "bucket_name" {
  description = "GCS bucket name. Used for Dataflow staging/temp and Dataproc script paths."
  type        = string
}

variable "dataproc_zone" {
  description = "GCP zone for ephemeral Dataproc clusters. Must be within var.region."
  type        = string
  default     = "asia-south1-b"
}

variable "dataflow_temp_prefix" {
  description = "GCS object prefix for Dataflow temp files."
  type        = string
  default     = "dataflow/temp"
}

variable "dataflow_staging_prefix" {
  description = "GCS object prefix for Dataflow staging files."
  type        = string
  default     = "dataflow/staging"
}

variable "environment" {
  description = "Deployment environment label."
  type        = string
  default     = "dev"
}
