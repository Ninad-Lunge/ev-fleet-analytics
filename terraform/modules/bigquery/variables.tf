variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "BigQuery dataset location. Must match the GCS bucket location."
  type        = string
  default     = "asia-south1"
}

variable "bucket_name" {
  description = "GCS bucket name used to construct the external table source URI."
  type        = string
}

variable "environment" {
  description = "Deployment environment label."
  type        = string
  default     = "dev"
}

variable "delete_contents_on_destroy" {
  description = <<-EOT
    If true, Terraform will delete all tables inside a dataset when the dataset
    resource is destroyed. Set to true only for dev/staging where clean teardown
    is needed. Always false in production to prevent data loss.
  EOT
  type    = bool
  default = false
}

variable "tags" {
  description = "Labels to apply to BigQuery datasets."
  type        = map(string)
  default     = {}
}
