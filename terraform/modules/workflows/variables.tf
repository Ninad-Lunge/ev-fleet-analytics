variable "project_id" {
  description = "GCP project ID. Injected into the workflow YAML template."
  type        = string
}

variable "region" {
  description = "GCP region. Injected into the workflow YAML template as the BigQuery location and Run API region."
  type        = string
}

variable "workflow_sa_email" {
  description = "Service account email for the workflow. Injected into the template and used by the Scheduler OAuth token."
  type        = string
}

variable "bucket_name" {
  description = "GCS data lake bucket name. Injected into the workflow YAML template."
  type        = string
}

variable "cloud_run_job_name" {
  description = "Cloud Run Job name to trigger in Step 1. Injected into the workflow YAML template."
  type        = string
  default     = "ev-generator"
}

variable "pipeline_cron" {
  description = "Cron schedule for the full pipeline trigger."
  type        = string
  default     = "0 2 * * *"
}

variable "scheduler_timezone" {
  description = "IANA timezone for the Cloud Scheduler job."
  type        = string
  default     = "Asia/Kolkata"
}

variable "workflow_file_path" {
  description = <<-EOT
    Path to the Cloud Workflows templatefile (.tftpl), relative to the Terraform
    root directory. The file uses Terraform's templatefile() function to inject
    project_id, region, bucket_name, workflow_sa, and run_job at apply time.
    This makes the workflow YAML fully portable across GCP projects.
  EOT
  type    = string
  default = "../workflows/nightly_pipeline.yaml.tftpl"
}

variable "environment" {
  description = "Deployment environment label."
  type        = string
  default     = "dev"
}
