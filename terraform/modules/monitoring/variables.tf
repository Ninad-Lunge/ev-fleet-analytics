variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "alert_email" {
  description = "Email address for alert notifications."
  type        = string
}

variable "environment" {
  description = "Deployment environment label."
  type        = string
  default     = "dev"
}

variable "workflow_name" {
  description = "Cloud Workflow name to monitor for failures."
  type        = string
  default     = "ev-nightly-pipeline"
}

variable "cloud_run_job_name" {
  description = "Cloud Run Job name to monitor for task failures."
  type        = string
  default     = "ev-generator"
}

variable "pubsub_subscription_backlog_threshold" {
  description = "Number of undelivered Pub/Sub messages that triggers the backlog alert. A high backlog signals the BQ subscription is not draining."
  type        = number
  default     = 10000
}
