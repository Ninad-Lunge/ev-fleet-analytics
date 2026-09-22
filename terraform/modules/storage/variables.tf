variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "bucket_name" {
  description = "Globally unique name for the GCS data lake bucket."
  type        = string
}

variable "location" {
  description = "GCS bucket location. Must match the BigQuery dataset region."
  type        = string
  default     = "ASIA-SOUTH1"
}

variable "environment" {
  description = "Deployment environment label (dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "lifecycle_age_days_to_nearline" {
  description = "Age in days after which raw/ objects transition to NEARLINE storage class."
  type        = number
  default     = 30
}

variable "lifecycle_age_days_to_coldline" {
  description = "Age in days after which raw/ objects transition to COLDLINE storage class."
  type        = number
  default     = 90
}

variable "lifecycle_age_days_to_delete" {
  description = "Age in days after which raw/ objects are deleted."
  type        = number
  default     = 365
}

variable "tags" {
  description = "Labels to apply to the bucket."
  type        = map(string)
  default     = {}
}
