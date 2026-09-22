# main.tf — root module
#
# This file wires all child modules together. It is the only place where
# module outputs are passed as inputs to other modules (cross-module wiring).
# Modules themselves have no knowledge of each other; all coupling is here.
#
# Dependency order (implicit via output references):
#   storage → iam, bigquery, ingestion, workflows, streaming
#   iam     → ingestion, workflows, pubsub (SA emails)
#   bigquery → pubsub (dataset/table IDs)
#   ingestion → iam (job name for run.invoker binding), monitoring
#   workflows → monitoring
#   pubsub   → monitoring

locals {
  # Common labels applied to every resource that supports labels.
  # Modules merge these with their own resource-specific labels.
  common_labels = merge(var.tags, {
    environment  = var.environment
    managed-by   = "terraform"
    platform     = "ev-fleet-analytics"
  })

  # ---------------------------------------------------------------------------
  # GCP service-agent email addresses. These are managed by Google, not created
  # by Terraform. They are constructed from the project number and used in IAM
  # bindings within the iam module.
  # ---------------------------------------------------------------------------

  # Pub/Sub service agent — needs BigQuery write access for the BQ subscription.
  pubsub_service_agent = "service-${var.project_number}@gcp-sa-pubsub.iam.gserviceaccount.com"

  # Compute Engine default service account — used by Cloud Build, Dataflow, Dataproc workers.
  compute_default_sa = "${var.project_number}-compute@developer.gserviceaccount.com"
}

# ---------------------------------------------------------------------------
# MODULE: storage
# Creates the GCS data lake bucket with lifecycle policies.
# Must be created before iam (bucket ARN needed for bucket-level bindings)
# and before bigquery (bucket name needed for external table source URI).
# ---------------------------------------------------------------------------
module "storage" {
  source = "./modules/storage"

  project_id  = var.project_id
  bucket_name = var.bucket_name
  location    = var.bucket_location
  environment = var.environment
  tags        = local.common_labels
}

# ---------------------------------------------------------------------------
# MODULE: iam
# Creates all service accounts and every IAM binding in one place.
# Centralised IAM makes audits and least-privilege reviews straightforward.
# Depends on storage (bucket name) and ingestion (Cloud Run job name) —
# the job name is passed as a variable so the iam module does not need to
# read ingestion module state directly.
# ---------------------------------------------------------------------------
module "iam" {
  source = "./modules/iam"

  project_id         = var.project_id
  region             = var.region
  project_number     = var.project_number
  bucket_name        = module.storage.bucket_name
  cloud_run_job_name = "ev-generator" # matches the job name in the ingestion module
  pubsub_service_agent  = local.pubsub_service_agent
  compute_default_sa    = local.compute_default_sa

  depends_on = [module.storage]
}

# ---------------------------------------------------------------------------
# MODULE: bigquery
# Creates datasets and all tables. Datasets use prevent_destroy to protect
# against accidental data loss. The BQML model is NOT managed here (the
# google provider does not support BigQuery ML model resources; the model is
# created by the nightly workflow).
# ---------------------------------------------------------------------------
module "bigquery" {
  source = "./modules/bigquery"

  project_id                 = var.project_id
  region                     = var.region
  bucket_name                = module.storage.bucket_name
  environment                = var.environment
  delete_contents_on_destroy = var.environment != "prod" # allow cleanup in dev/staging only
  tags                       = local.common_labels

  depends_on = [module.storage]
}

# ---------------------------------------------------------------------------
# MODULE: pubsub
# Creates the ev-telemetry topic and both subscriptions (BQ + Beam).
# Requires the BigQuery dataset/table to exist before the BQ subscription
# can be validated by the API.
# ---------------------------------------------------------------------------
module "pubsub" {
  source = "./modules/pubsub"

  project_id              = var.project_id
  bq_dataset_raw          = module.bigquery.ev_raw_dataset_id
  bq_ack_deadline_seconds = var.pubsub_bq_ack_deadline_seconds
  environment             = var.environment

  depends_on = [module.bigquery]
}

# ---------------------------------------------------------------------------
# MODULE: ingestion
# Creates Artifact Registry, Cloud Run Job, and the 01:00 IST Scheduler.
# Runs after iam so the SA email is available and the SA exists before the
# Cloud Run job references it.
# ---------------------------------------------------------------------------
module "ingestion" {
  source = "./modules/ingestion"

  project_id       = var.project_id
  region           = var.region
  bucket_name      = module.storage.bucket_name
  container_image  = var.container_image
  ingest_sa_email  = module.iam.ingest_sa_email
  ingestion_cron   = var.ingestion_cron
  scheduler_timezone = var.scheduler_timezone
  vehicles_per_run = var.vehicles_per_run
  interval_seconds = var.interval_seconds
  environment      = var.environment

  depends_on = [module.iam, module.storage]
}

# ---------------------------------------------------------------------------
# MODULE: workflows
# Deploys the Cloud Workflow from the YAML source file and creates the
# 02:00 IST Scheduler that triggers the full pipeline.
# ---------------------------------------------------------------------------
module "workflows" {
  source = "./modules/workflows"

  project_id         = var.project_id
  region             = var.region
  bucket_name        = module.storage.bucket_name
  workflow_sa_email  = module.iam.workflow_sa_email
  cloud_run_job_name = module.ingestion.cloud_run_job_name
  pipeline_cron      = var.pipeline_cron
  scheduler_timezone = var.scheduler_timezone
  workflow_file_path = var.workflow_file_path
  environment        = var.environment

  depends_on = [module.iam, module.ingestion]
}

# ---------------------------------------------------------------------------
# MODULE: monitoring
# Cloud Monitoring alert policies and notification channel.
# Created after ingestion and workflows so resource names are resolved.
# ---------------------------------------------------------------------------
module "monitoring" {
  source = "./modules/monitoring"

  project_id                        = var.project_id
  alert_email                       = var.alert_notification_email
  environment                       = var.environment
  workflow_name                     = module.workflows.workflow_name
  cloud_run_job_name                = module.ingestion.cloud_run_job_name
  pubsub_subscription_backlog_threshold = 10000

  depends_on = [module.ingestion, module.workflows, module.pubsub]
}

# ---------------------------------------------------------------------------
# MODULE: streaming
# Documents Dataflow and Dataproc configuration as locals/outputs.
# Does NOT create live Dataflow jobs or Dataproc clusters (ephemeral compute).
# Outputs are consumed by CI scripts and the operational runbook.
# ---------------------------------------------------------------------------
module "streaming" {
  source = "./modules/streaming"

  project_id          = var.project_id
  region              = var.region
  bucket_name         = module.storage.bucket_name
  dataproc_zone       = var.dataproc_zone
  dataflow_temp_prefix    = var.dataflow_temp_prefix
  dataflow_staging_prefix = "dataflow/staging"
  environment             = var.environment

  depends_on = [module.storage, module.bigquery, module.pubsub]
}
