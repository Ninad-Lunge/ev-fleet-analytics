# modules/iam/main.tf
#
# All service accounts and IAM bindings in one module.
# Centralising IAM makes least-privilege audits straightforward: every
# permission granted in this project is visible here.
#
# Binding style: _member (additive) over _binding (authoritative).
# _binding REPLACES the entire role's member list, which causes outages if
# another process (Console, gcloud, another Terraform workspace) has added
# members. _member is additive and idempotent — safer for shared projects.

# =============================================================================
# SERVICE ACCOUNTS
# =============================================================================

# Runs the Cloud Run ingestion job. Granted only objectCreator on the bucket
# and run.invoker on the specific job — nothing else.
resource "google_service_account" "ingest_runner" {
  project      = var.project_id
  account_id   = "ev-ingest-runner"
  display_name = "EV telemetry ingestion runner"
  description  = "Identity for the Cloud Run ev-generator job. Least-privilege: write to data lake only."
}

# Runs Cloud Workflows and calls BigQuery + Cloud Run APIs on behalf of the pipeline.
resource "google_service_account" "workflow_runner" {
  project      = var.project_id
  account_id   = "ev-workflow-runner"
  display_name = "EV pipeline workflow orchestrator"
  description  = "Identity for Cloud Workflows ev-nightly-pipeline and its Cloud Scheduler trigger."
}

# =============================================================================
# BUCKET-LEVEL BINDINGS
# Scoped to the specific bucket only — not project-wide storage roles.
# =============================================================================

# ev-ingest-runner: CREATE objects in the data lake.
# objectCreator lets it write new Parquet files but cannot read, list, or delete.
resource "google_storage_bucket_iam_member" "ingest_runner_object_creator" {
  bucket = var.bucket_name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.ingest_runner.email}"
}

# ev-workflow-runner: LIST + READ objects in the data lake.
# Required so the BigQuery Jobs API can glob raw/telemetry/* when querying
# the external table (the BQ job runs as the workflow SA).
resource "google_storage_bucket_iam_member" "workflow_runner_object_viewer" {
  bucket = var.bucket_name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.workflow_runner.email}"
}

# =============================================================================
# CLOUD RUN JOB-LEVEL BINDING
# ev-ingest-runner: invoke the specific Cloud Run job.
# Scoped to the job resource, not project-wide run.invoker.
# =============================================================================

resource "google_cloud_run_v2_job_iam_member" "ingest_runner_invoker" {
  project  = var.project_id
  location = var.region
  name     = var.cloud_run_job_name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.ingest_runner.email}"
}

# =============================================================================
# PROJECT-LEVEL BINDINGS — ev-workflow-runner
# Grants the minimum roles the workflow needs to run BigQuery jobs and
# invoke Cloud Run jobs across the project.
# =============================================================================

# Submit and monitor BigQuery jobs.
resource "google_project_iam_member" "workflow_runner_bq_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.workflow_runner.email}"
}

# Read and write BigQuery table data (CTAS, INSERT, DELETE).
resource "google_project_iam_member" "workflow_runner_bq_data_editor" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${google_service_account.workflow_runner.email}"
}

# Write Cloud Logging entries (workflow step logs).
resource "google_project_iam_member" "workflow_runner_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.workflow_runner.email}"
}

# Invoke Cloud Run jobs (for Step 1 of the workflow: trigger ev-generator).
resource "google_project_iam_member" "workflow_runner_run_invoker" {
  project = var.project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:${google_service_account.workflow_runner.email}"
}

# Allow the scheduler to trigger workflow executions.
resource "google_project_iam_member" "workflow_runner_workflows_invoker" {
  project = var.project_id
  role    = "roles/workflows.invoker"
  member  = "serviceAccount:${google_service_account.workflow_runner.email}"
}

# =============================================================================
# PROJECT-LEVEL BINDINGS — Compute Engine default SA
# Used by Cloud Build workers, Dataflow workers, and Dataproc workers.
# These are the minimum roles discovered during deployment.
# In production, each service (Build, Dataflow, Dataproc) should have its own
# dedicated SA. Consolidated here for the learning platform.
# =============================================================================

# Push built images to Artifact Registry (Cloud Build).
resource "google_project_iam_member" "compute_sa_ar_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${var.compute_default_sa}"
}

# Read source tarballs from the Cloud Build staging bucket.
resource "google_project_iam_member" "compute_sa_storage_viewer" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${var.compute_default_sa}"
}

# Write Cloud Build and worker logs.
resource "google_project_iam_member" "compute_sa_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${var.compute_default_sa}"
}

# Allow Dataflow workers to communicate with the Dataflow control plane.
resource "google_project_iam_member" "compute_sa_dataflow_worker" {
  project = var.project_id
  role    = "roles/dataflow.worker"
  member  = "serviceAccount:${var.compute_default_sa}"
}

# Allow Dataflow workers to read from the Pub/Sub subscription.
resource "google_project_iam_member" "compute_sa_pubsub_subscriber" {
  project = var.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:${var.compute_default_sa}"
}

# Allow Dataflow and Dataproc workers to write to BigQuery.
resource "google_project_iam_member" "compute_sa_bq_data_editor" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${var.compute_default_sa}"
}

# Allow Dataproc workers to communicate with the Dataproc control plane.
resource "google_project_iam_member" "compute_sa_dataproc_worker" {
  project = var.project_id
  role    = "roles/dataproc.worker"
  member  = "serviceAccount:${var.compute_default_sa}"
}

# =============================================================================
# PROJECT-LEVEL BINDINGS — Pub/Sub service agent
# The Pub/Sub managed service writes directly to BigQuery for the BQ
# subscription. It uses its own service agent identity (not the user's).
# =============================================================================

# Write rows to ev_raw.telemetry_stream.
resource "google_project_iam_member" "pubsub_sa_bq_data_editor" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${var.pubsub_service_agent}"
}

# Read BigQuery table metadata (schema, partition info) for the BQ subscription.
resource "google_project_iam_member" "pubsub_sa_bq_metadata_viewer" {
  project = var.project_id
  role    = "roles/bigquery.metadataViewer"
  member  = "serviceAccount:${var.pubsub_service_agent}"
}
