output "dataflow_subscription_path" {
  description = "Full Pub/Sub subscription path for the Dataflow Beam pipeline."
  value       = local.dataflow.subscription_path
}

output "dataflow_output_table" {
  description = "BigQuery output table for the Dataflow enrichment pipeline."
  value       = local.dataflow.output_table
}

output "dataflow_temp_location" {
  description = "GCS temp location for Dataflow jobs."
  value       = local.dataflow.temp_location
}

output "dataflow_staging_location" {
  description = "GCS staging location for Dataflow job artifacts."
  value       = local.dataflow.staging_location
}

output "dataproc_spark_script_gcs_path" {
  description = "GCS path of the PySpark battery health script for Dataproc jobs."
  value       = local.dataproc.job_script_path
}
