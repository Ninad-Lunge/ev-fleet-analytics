# modules/bigquery/main.tf
#
# All BigQuery datasets and tables for the EV Fleet Analytics platform.
#
# NOTE: The BigQuery ML model (battery_anomaly_model) is NOT managed here.
# The Terraform google provider does not support the google_bigquery_ml_model
# resource type. The model is created and retrained by the nightly Cloud
# Workflow via a CREATE OR REPLACE MODEL SQL statement. This is intentional
# and appropriate: ML model lifecycle (train, evaluate, retrain) belongs in
# the data pipeline, not in infrastructure code.
#
# Layer naming:
#   ev_raw       — raw ingested data, external and native tables
#   ev_analytics — modeled star schema + ML features + predictions

locals {
  dataset_labels = merge(var.tags, {
    environment = var.environment
    managed-by  = "terraform"
  })
}

# =============================================================================
# DATASETS
# =============================================================================

# Raw landing zone: external table pointing at GCS + native tables refreshed
# nightly by the Cloud Workflow.
resource "google_bigquery_dataset" "ev_raw" {
  project                     = var.project_id
  dataset_id                  = "ev_raw"
  location                    = var.region
  description                 = "EV telemetry raw landing zone. Contains external table over GCS and native refreshed copies."
  delete_contents_on_destroy  = var.delete_contents_on_destroy
  labels                      = local.dataset_labels

  # Prevent accidental dataset deletion via terraform destroy.
  # Remove this lifecycle block only when intentionally decommissioning.
  lifecycle {
    prevent_destroy = true
  }
}

# Analytics layer: star schema, ML feature table, and predictions.
resource "google_bigquery_dataset" "ev_analytics" {
  project                     = var.project_id
  dataset_id                  = "ev_analytics"
  location                    = var.region
  description                 = "EV analytics star schema, ML feature table, and daily predictions."
  delete_contents_on_destroy  = var.delete_contents_on_destroy
  labels                      = local.dataset_labels

  lifecycle {
    prevent_destroy = true
  }
}

# =============================================================================
# ev_raw TABLES
# =============================================================================

# External table over the GCS data lake.
# Hive partitioning on date= lets BigQuery surface the partition directory
# as a queryable column without it being in the Parquet files.
resource "google_bigquery_table" "telemetry_ext" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.ev_raw.dataset_id
  table_id            = "telemetry_ext"
  description         = "External table over gs://${var.bucket_name}/raw/telemetry/*. Queries the data lake in-place; no storage cost."
  deletion_protection = false # external tables can be recreated cheaply

  external_data_configuration {
    autodetect    = false
    source_format = "PARQUET"
    source_uris   = ["gs://${var.bucket_name}/raw/telemetry/*"]

    # Hive-style partitioning: the 'date' column is derived from the
    # date=YYYY-MM-DD directory names, not from the Parquet file contents.
    hive_partitioning_options {
      mode                     = "AUTO"
      source_uri_prefix        = "gs://${var.bucket_name}/raw/telemetry/"
      require_partition_filter = false
    }

    schema = jsonencode([
      { name = "vehicle_id",           type = "STRING",    mode = "NULLABLE" },
      { name = "timestamp",            type = "TIMESTAMP", mode = "NULLABLE" },
      { name = "latitude",             type = "FLOAT64",   mode = "NULLABLE" },
      { name = "longitude",            type = "FLOAT64",   mode = "NULLABLE" },
      { name = "battery_soc",          type = "FLOAT64",   mode = "NULLABLE" },
      { name = "battery_voltage",      type = "FLOAT64",   mode = "NULLABLE" },
      { name = "battery_temperature",  type = "FLOAT64",   mode = "NULLABLE" },
      { name = "motor_temperature",    type = "FLOAT64",   mode = "NULLABLE" },
      { name = "speed",                type = "FLOAT64",   mode = "NULLABLE" },
      { name = "odometer",             type = "FLOAT64",   mode = "NULLABLE" },
      { name = "charging_status",      type = "BOOL",      mode = "NULLABLE" },
      { name = "power_consumption",    type = "FLOAT64",   mode = "NULLABLE" },
    ])
  }

  depends_on = [google_bigquery_dataset.ev_raw]
}

# Native materialized copy of the external table.
# PARTITION BY event_date enables partition pruning (days scanned).
# CLUSTER BY vehicle_id reduces bytes within a partition for per-vehicle queries.
resource "google_bigquery_table" "telemetry" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.ev_raw.dataset_id
  table_id            = "telemetry"
  description         = "Native partitioned+clustered copy of telemetry. Refreshed nightly by the Cloud Workflow (CTAS from telemetry_ext)."
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "event_date"
  }

  clustering = ["vehicle_id"]

  schema = jsonencode([
    { name = "vehicle_id",          type = "STRING",    mode = "NULLABLE" },
    { name = "timestamp",           type = "TIMESTAMP", mode = "NULLABLE" },
    { name = "latitude",            type = "FLOAT64",   mode = "NULLABLE" },
    { name = "longitude",           type = "FLOAT64",   mode = "NULLABLE" },
    { name = "battery_soc",         type = "FLOAT64",   mode = "NULLABLE" },
    { name = "battery_voltage",     type = "FLOAT64",   mode = "NULLABLE" },
    { name = "battery_temperature", type = "FLOAT64",   mode = "NULLABLE" },
    { name = "motor_temperature",   type = "FLOAT64",   mode = "NULLABLE" },
    { name = "speed",               type = "FLOAT64",   mode = "NULLABLE" },
    { name = "odometer",            type = "FLOAT64",   mode = "NULLABLE" },
    { name = "charging_status",     type = "BOOL",      mode = "NULLABLE" },
    { name = "power_consumption",   type = "FLOAT64",   mode = "NULLABLE" },
    { name = "event_date",          type = "DATE",      mode = "NULLABLE" },
  ])

  depends_on = [google_bigquery_dataset.ev_raw]
}

# Real-time streaming target for the Pub/Sub → BigQuery subscription (Phase 4a).
# ingest_time uses a DEFAULT expression so BQ stamps each row on arrival.
resource "google_bigquery_table" "telemetry_stream" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.ev_raw.dataset_id
  table_id            = "telemetry_stream"
  description         = "Streaming target for the Pub/Sub ev-telemetry-bq subscription. Rows arrive in near-real-time."
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "timestamp"
  }

  clustering = ["vehicle_id"]

  schema = jsonencode([
    { name = "vehicle_id",          type = "STRING",    mode = "NULLABLE" },
    { name = "timestamp",           type = "TIMESTAMP", mode = "NULLABLE" },
    { name = "latitude",            type = "FLOAT64",   mode = "NULLABLE" },
    { name = "longitude",           type = "FLOAT64",   mode = "NULLABLE" },
    { name = "battery_soc",         type = "FLOAT64",   mode = "NULLABLE" },
    { name = "battery_voltage",     type = "FLOAT64",   mode = "NULLABLE" },
    { name = "battery_temperature", type = "FLOAT64",   mode = "NULLABLE" },
    { name = "motor_temperature",   type = "FLOAT64",   mode = "NULLABLE" },
    { name = "speed",               type = "FLOAT64",   mode = "NULLABLE" },
    { name = "odometer",            type = "FLOAT64",   mode = "NULLABLE" },
    { name = "charging_status",     type = "BOOL",      mode = "NULLABLE" },
    { name = "power_consumption",   type = "FLOAT64",   mode = "NULLABLE" },
    {
      name                    = "ingest_time"
      type                    = "TIMESTAMP"
      mode                    = "NULLABLE"
      defaultValueExpression  = "CURRENT_TIMESTAMP()"
      description             = "Server-side arrival timestamp, set automatically by BigQuery."
    },
  ])

  depends_on = [google_bigquery_dataset.ev_raw]
}

# Enriched telemetry with anomaly flags.
# Written by: (a) the nightly Workflow SQL step, (b) the Dataflow Beam pipeline.
resource "google_bigquery_table" "telemetry_enriched" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.ev_raw.dataset_id
  table_id            = "telemetry_enriched"
  description         = "Telemetry enriched with anomaly flags (is_anomaly, anomaly_reason). Written by the nightly SQL enrichment step or by Dataflow."
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "timestamp"
  }

  clustering = ["vehicle_id"]

  schema = jsonencode([
    { name = "vehicle_id",          type = "STRING",    mode = "NULLABLE" },
    { name = "timestamp",           type = "TIMESTAMP", mode = "NULLABLE" },
    { name = "battery_soc",         type = "FLOAT64",   mode = "NULLABLE" },
    { name = "battery_temperature", type = "FLOAT64",   mode = "NULLABLE" },
    { name = "motor_temperature",   type = "FLOAT64",   mode = "NULLABLE" },
    { name = "speed",               type = "FLOAT64",   mode = "NULLABLE" },
    { name = "power_consumption",   type = "FLOAT64",   mode = "NULLABLE" },
    { name = "charging_status",     type = "BOOL",      mode = "NULLABLE" },
    { name = "is_anomaly",          type = "BOOL",      mode = "NULLABLE",   description = "True if any anomaly rule fired on this reading." },
    { name = "anomaly_reason",      type = "STRING",    mode = "NULLABLE",   description = "Comma-separated anomaly codes, e.g. battery_temp_high,low_soc_while_driving." },
    { name = "processed_at",        type = "TIMESTAMP", mode = "NULLABLE",   description = "Timestamp when this row was enriched." },
  ])

  depends_on = [google_bigquery_dataset.ev_raw]
}

# =============================================================================
# ev_analytics TABLES — Star schema
# =============================================================================

# Fact table: one row per telemetry reading. Central fact in the star schema.
resource "google_bigquery_table" "fact_telemetry" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.ev_analytics.dataset_id
  table_id            = "fact_telemetry"
  description         = "Star schema fact: one row per telemetry reading. Partitioned by day, clustered by vehicle for cost-efficient queries."
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "event_date"
  }

  clustering = ["vehicle_id"]

  schema = jsonencode([
    { name = "vehicle_id",          type = "STRING",    mode = "NULLABLE" },
    { name = "timestamp",           type = "TIMESTAMP", mode = "NULLABLE" },
    { name = "event_date",          type = "DATE",      mode = "NULLABLE" },
    { name = "battery_soc",         type = "FLOAT64",   mode = "NULLABLE" },
    { name = "battery_voltage",     type = "FLOAT64",   mode = "NULLABLE" },
    { name = "battery_temperature", type = "FLOAT64",   mode = "NULLABLE" },
    { name = "motor_temperature",   type = "FLOAT64",   mode = "NULLABLE" },
    { name = "speed",               type = "FLOAT64",   mode = "NULLABLE" },
    { name = "odometer",            type = "FLOAT64",   mode = "NULLABLE" },
    { name = "power_consumption",   type = "FLOAT64",   mode = "NULLABLE" },
    { name = "charging_status",     type = "BOOL",      mode = "NULLABLE" },
    { name = "latitude",            type = "FLOAT64",   mode = "NULLABLE" },
    { name = "longitude",           type = "FLOAT64",   mode = "NULLABLE" },
  ])

  depends_on = [google_bigquery_dataset.ev_analytics]
}

# Dimension: vehicle master data. In a real system this would be loaded from
# a fleet registry; in this platform it is synthesized from vehicle_id.
resource "google_bigquery_table" "dim_vehicle" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.ev_analytics.dataset_id
  table_id            = "dim_vehicle"
  description         = "Vehicle dimension: model, manufacture year, battery capacity, fleet, region. Refreshed nightly from distinct vehicle_ids in fact_telemetry."
  deletion_protection = false

  schema = jsonencode([
    { name = "vehicle_id",           type = "STRING", mode = "NULLABLE" },
    { name = "model",                type = "STRING", mode = "NULLABLE" },
    { name = "manufacture_year",     type = "INT64",  mode = "NULLABLE" },
    { name = "battery_capacity_kwh", type = "FLOAT64",mode = "NULLABLE" },
    { name = "fleet",                type = "STRING", mode = "NULLABLE" },
    { name = "region",               type = "STRING", mode = "NULLABLE" },
  ])

  depends_on = [google_bigquery_dataset.ev_analytics]
}

# PySpark output from Dataproc Phase 5 job.
resource "google_bigquery_table" "battery_health_spark" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.ev_analytics.dataset_id
  table_id            = "battery_health_spark"
  description         = "Per-vehicle lifetime battery health metrics computed by the PySpark Dataproc job. Written on demand; not in the nightly workflow."
  deletion_protection = false

  schema = jsonencode([
    { name = "vehicle_id",        type = "STRING",  mode = "NULLABLE" },
    { name = "avg_soc_pct",       type = "FLOAT64", mode = "NULLABLE" },
    { name = "avg_batt_temp_c",   type = "FLOAT64", mode = "NULLABLE" },
    { name = "max_batt_temp_c",   type = "FLOAT64", mode = "NULLABLE" },
    { name = "avg_voltage",       type = "FLOAT64", mode = "NULLABLE" },
    { name = "avg_motor_temp_c",  type = "FLOAT64", mode = "NULLABLE" },
    { name = "avg_speed_kmh",     type = "FLOAT64", mode = "NULLABLE" },
    { name = "avg_power_kw",      type = "FLOAT64", mode = "NULLABLE" },
    { name = "total_energy_kwh",  type = "FLOAT64", mode = "NULLABLE" },
    { name = "total_charged_kwh", type = "FLOAT64", mode = "NULLABLE" },
    { name = "charging_hours",    type = "FLOAT64", mode = "NULLABLE" },
    { name = "total_readings",    type = "INT64",   mode = "NULLABLE" },
    { name = "health_score",      type = "FLOAT64", mode = "NULLABLE", description = "Synthetic score: 100 - (avg_batt_temp_c - 25) * 2. Lower = worse." },
  ])

  depends_on = [google_bigquery_dataset.ev_analytics]
}

# ML feature table: one row per vehicle per day. Label derived from p95 threshold.
resource "google_bigquery_table" "ml_features" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.ev_analytics.dataset_id
  table_id            = "ml_features"
  description         = "Daily per-vehicle features for BigQuery ML. Refreshed nightly by the Cloud Workflow. Label: max_batt_temp > fleet p95."
  deletion_protection = false

  schema = jsonencode([
    { name = "vehicle_id",               type = "STRING",  mode = "NULLABLE" },
    { name = "event_date",               type = "DATE",    mode = "NULLABLE" },
    { name = "avg_soc",                  type = "FLOAT64", mode = "NULLABLE" },
    { name = "min_soc",                  type = "FLOAT64", mode = "NULLABLE" },
    { name = "avg_batt_temp",            type = "FLOAT64", mode = "NULLABLE" },
    { name = "max_batt_temp",            type = "FLOAT64", mode = "NULLABLE" },
    { name = "avg_voltage",              type = "FLOAT64", mode = "NULLABLE" },
    { name = "voltage_stddev",           type = "FLOAT64", mode = "NULLABLE" },
    { name = "avg_motor_temp",           type = "FLOAT64", mode = "NULLABLE" },
    { name = "avg_speed",                type = "FLOAT64", mode = "NULLABLE" },
    { name = "avg_power",                type = "FLOAT64", mode = "NULLABLE" },
    { name = "daily_energy_kwh",         type = "FLOAT64", mode = "NULLABLE" },
    { name = "charging_intervals",       type = "INT64",   mode = "NULLABLE" },
    { name = "health_score",             type = "FLOAT64", mode = "NULLABLE" },
    { name = "lifetime_energy_kwh",      type = "FLOAT64", mode = "NULLABLE" },
    { name = "lifetime_charging_hours",  type = "FLOAT64", mode = "NULLABLE" },
    { name = "is_anomaly",               type = "BOOL",    mode = "NULLABLE", description = "Label: TRUE if this vehicle-day's max_batt_temp exceeded the fleet p95." },
  ])

  depends_on = [google_bigquery_dataset.ev_analytics]
}

# ML predictions table: daily scored output from ML.PREDICT.
# Partitioned so historical predictions are queryable by date without full scans.
resource "google_bigquery_table" "predictions" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.ev_analytics.dataset_id
  table_id            = "predictions"
  description         = "Daily per-vehicle anomaly predictions from ML.PREDICT on battery_anomaly_model. Refreshed nightly."
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "event_date"
  }

  clustering = ["vehicle_id"]

  schema = jsonencode([
    { name = "vehicle_id",            type = "STRING",    mode = "NULLABLE" },
    { name = "event_date",            type = "DATE",      mode = "NULLABLE" },
    { name = "predicted_is_anomaly",  type = "BOOL",      mode = "NULLABLE" },
    { name = "anomaly_probability",   type = "FLOAT64",   mode = "NULLABLE", description = "Probability of is_anomaly=TRUE from the logistic regression model. Range 0-1." },
    { name = "max_batt_temp",         type = "FLOAT64",   mode = "NULLABLE" },
    { name = "avg_batt_temp",         type = "FLOAT64",   mode = "NULLABLE" },
    { name = "health_score",          type = "FLOAT64",   mode = "NULLABLE" },
    { name = "refreshed_at",          type = "TIMESTAMP", mode = "NULLABLE", description = "Timestamp of the last nightly pipeline run that refreshed this row." },
  ])

  depends_on = [google_bigquery_dataset.ev_analytics]
}
