# variables.tf
# All inputs are declared here with types, descriptions, defaults, and validation
# blocks. Platform engineering principle: fail fast at plan time with a clear
# message rather than failing at apply time with a cryptic API error.

# ---------------------------------------------------------------------------
# CORE PROJECT SETTINGS
# ---------------------------------------------------------------------------

variable "project_id" {
  description = "GCP project ID where all resources will be deployed."
  type        = string

  validation {
    condition     = length(var.project_id) > 0
    error_message = "project_id must not be empty."
  }
}

variable "project_number" {
  description = <<-EOT
    Numeric GCP project number (e.g. 355587796204). Required to construct
    service-agent email addresses (Pub/Sub, Cloud Run, etc.) because GCP
    service agents are identified by project number, not project ID.
    Find it with: gcloud projects describe <project_id> --format='value(projectNumber)'
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.project_number))
    error_message = "project_number must contain only digits."
  }
}

variable "region" {
  description = "Default GCP region for all regional resources."
  type        = string
  default     = "asia-south1"
}

variable "environment" {
  description = "Deployment environment. Controls labels and, optionally, resource sizing."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

# ---------------------------------------------------------------------------
# STORAGE
# ---------------------------------------------------------------------------

variable "bucket_name" {
  description = <<-EOT
    Globally unique GCS bucket name for the data lake.
    GCS bucket names are global across all GCP projects, so include a
    project-specific suffix to guarantee uniqueness.
  EOT
  type        = string

  validation {
    # GCS naming rules: 3-63 chars, lowercase letters, numbers, hyphens, dots.
    condition     = can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be 3-63 chars, lowercase, and start/end with a letter or number."
  }
}

variable "bucket_location" {
  description = "GCS bucket location. Must match the BigQuery dataset location to avoid cross-region costs."
  type        = string
  default     = "ASIA-SOUTH1"
}

# ---------------------------------------------------------------------------
# CONTAINER IMAGE
# ---------------------------------------------------------------------------

variable "container_image" {
  description = <<-EOT
    Full container image URI for the telemetry generator, including tag.
    Format: <region>-docker.pkg.dev/<project>/<repo>/<image>:<tag>
    Example: asia-south1-docker.pkg.dev/my-project/ev-fleet/ev-generator:v1
    Pinning to a tag (not :latest) ensures infrastructure changes are auditable.
  EOT
  type        = string

  validation {
    condition     = can(regex(":.+$", var.container_image))
    error_message = "container_image must include a tag (e.g. :v1). Never use :latest in production."
  }
}

# ---------------------------------------------------------------------------
# SCHEDULING
# ---------------------------------------------------------------------------

variable "ingestion_cron" {
  description = "Cron schedule for the Cloud Run ingestion job (step 1). Default: 01:00 IST daily."
  type        = string
  default     = "0 1 * * *"
}

variable "pipeline_cron" {
  description = "Cron schedule for the full Cloud Workflows pipeline (step 2+). Default: 02:00 IST daily (after ingestion)."
  type        = string
  default     = "0 2 * * *"
}

variable "scheduler_timezone" {
  description = "IANA timezone for Cloud Scheduler jobs."
  type        = string
  default     = "Asia/Kolkata"
}

# ---------------------------------------------------------------------------
# INGESTION TUNING
# ---------------------------------------------------------------------------

variable "vehicles_per_run" {
  description = "Number of simulated vehicles per ingestion run. Keep small during development."
  type        = number
  default     = 100
}

variable "interval_seconds" {
  description = "Telemetry sampling interval in seconds. Must evenly divide 86400. Default: 300 (5 min)."
  type        = number
  default     = 300
}

# ---------------------------------------------------------------------------
# MONITORING + ALERTING
# ---------------------------------------------------------------------------

variable "alert_notification_email" {
  description = "Email address to receive Cloud Monitoring alert notifications."
  type        = string

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.alert_notification_email))
    error_message = "alert_notification_email must be a valid email address."
  }
}

# ---------------------------------------------------------------------------
# PUB/SUB
# ---------------------------------------------------------------------------

variable "pubsub_bq_ack_deadline_seconds" {
  description = "Ack deadline (seconds) for the BigQuery Pub/Sub subscription. Must be 10-600."
  type        = number
  default     = 600

  validation {
    condition     = var.pubsub_bq_ack_deadline_seconds >= 10 && var.pubsub_bq_ack_deadline_seconds <= 600
    error_message = "pubsub_bq_ack_deadline_seconds must be between 10 and 600."
  }
}

# ---------------------------------------------------------------------------
# WORKFLOWS
# ---------------------------------------------------------------------------

variable "workflow_file_path" {
  description = <<-EOT
    Path to the Cloud Workflows templatefile (.tftpl), relative to the Terraform root.
    The template is rendered with templatefile() at apply time, injecting project_id,
    region, bucket_name and other variables — making the YAML fully portable.
  EOT
  type        = string
  default     = "../workflows/nightly_pipeline.yaml.tftpl"
}

# ---------------------------------------------------------------------------
# STREAMING / BATCH (ephemeral resources — not managed by Terraform)
# ---------------------------------------------------------------------------

variable "dataflow_temp_prefix" {
  description = "GCS object prefix for Dataflow temp files. Used in the streaming module locals."
  type        = string
  default     = "dataflow/temp"
}

variable "dataproc_zone" {
  description = "GCP zone for ephemeral Dataproc clusters. Must be within var.region."
  type        = string
  default     = "asia-south1-b"
}

# ---------------------------------------------------------------------------
# LABELS / TAGS
# ---------------------------------------------------------------------------

variable "tags" {
  description = <<-EOT
    Additional labels to apply to all resources that support them.
    Platform-managed labels (environment, managed-by) are merged automatically
    in each module — callers should not duplicate them here.
  EOT
  type    = map(string)
  default = {}
}
