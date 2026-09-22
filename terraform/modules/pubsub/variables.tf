variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "bq_dataset_raw" {
  description = "BigQuery dataset ID for the raw zone (ev_raw). Used to construct the BQ subscription table path."
  type        = string
}

variable "bq_ack_deadline_seconds" {
  description = "Acknowledgement deadline (seconds) for the BigQuery subscription."
  type        = number
  default     = 600
}

variable "environment" {
  description = "Deployment environment label."
  type        = string
  default     = "dev"
}
