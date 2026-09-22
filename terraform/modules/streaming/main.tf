# modules/streaming/main.tf
#
# This module does NOT manage live Dataflow jobs or Dataproc clusters.
#
# WHY: Dataflow (streaming) and Dataproc (Spark batch) are EPHEMERAL compute.
# They should not have persistent Terraform state because:
#   - A streaming Dataflow job in state will bill continuously.
#   - A Dataproc cluster in state will bill even when idle.
#   - Terraform does not gracefully drain Dataflow jobs; a destroy leaves
#     in-flight messages unprocessed.
#   - Both services are inherently operational: launch when needed, stop after.
#
# This module instead:
#   1. Declares all configuration as locals for reference and CI script use.
#   2. Reads the existing GCS bucket as a data source (not managing it).
#   3. Provides a detailed operational runbook in comments.
#   4. Exposes the config values as outputs for CI pipelines to consume.
#
# CORRECT APPROACH for production: trigger Dataflow/Dataproc jobs from
# Cloud Workflows, Cloud Build, or a CI pipeline — not from Terraform apply.

# ---------------------------------------------------------------------------
# No data sources or managed resources in this module.
# All configuration is expressed as locals and surfaced as outputs.
# The bucket is managed by the storage module; it is referenced here
# only by name (a variable) to construct GCS path strings.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Configuration locals: single source of truth for all job parameters.
# Referenced by outputs and operational runbook commands below.
# ---------------------------------------------------------------------------

locals {
  # ---- Dataflow (Apache Beam) streaming pipeline ----
  dataflow = {
    job_name            = "ev-telemetry-enrich"
    subscription_path   = "projects/${var.project_id}/subscriptions/ev-telemetry-beam"
    output_table        = "${var.project_id}:ev_raw.telemetry_enriched"
    region              = var.region
    temp_location       = "gs://${var.bucket_name}/${var.dataflow_temp_prefix}"
    staging_location    = "gs://${var.bucket_name}/${var.dataflow_staging_prefix}"
    num_workers         = 1
    max_num_workers     = 1
    machine_type        = "e2-small"
    pipeline_script     = "dataflow/telemetry_pipeline.py"
    beam_venv           = ".beam-venv"
  }

  # ---- Dataproc (PySpark) batch pipeline ----
  dataproc = {
    cluster_name    = "ev-spark"
    zone            = var.dataproc_zone
    machine_type    = "e2-standard-2"
    image_version   = "2.1-debian11"
    bq_connector    = "com.google.cloud.spark:spark-bigquery-with-dependencies_2.12:0.34.0"
    job_script_path = "gs://${var.bucket_name}/spark/battery_health.py"
    input_path      = "gs://${var.bucket_name}/raw/telemetry"
    output_dataset  = "ev_analytics"
    output_table    = "battery_health_spark"
  }
}

# =============================================================================
# OPERATIONAL RUNBOOK
# =============================================================================
#
# ─────────────────────────────────────────────────────────────────────────────
# DATAFLOW — Apache Beam streaming enrichment pipeline (Phase 4b)
# ─────────────────────────────────────────────────────────────────────────────
#
# IMPORTANT: Always drain or cancel the job when done. A running streaming job
# bills ~$0.02–0.05/hour (e2-small). Never leave it running unattended.
#
# 1. Set up the Beam virtualenv (once per machine):
#    cd <repo>/ev-fleet-analytics
#    python3.12 -m venv .beam-venv
#    .beam-venv/bin/pip install "setuptools<81" wheel
#    .beam-venv/bin/pip install --no-build-isolation "apache-beam[gcp]==2.60.0"
#
# 2. Launch (uses config from locals above):
#    cd <repo>/ev-fleet-analytics/dataflow
#    ../.beam-venv/bin/python telemetry_pipeline.py \
#      --runner=DataflowRunner \
#      --project=<project_id> \
#      --region=<region> \
#      --temp_location=gs://<bucket>/dataflow/temp \
#      --staging_location=gs://<bucket>/dataflow/staging \
#      --subscription=projects/<project>/subscriptions/ev-telemetry-beam \
#      --output_table=<project>:ev_raw.telemetry_enriched \
#      --num_workers=1 --max_num_workers=1 \
#      --machine_type=e2-small \
#      --job_name=ev-telemetry-enrich
#
# 3. Monitor:
#    gcloud dataflow jobs list --region=<region> --status=active
#
# 4. DRAIN (process in-flight messages then stop):
#    gcloud dataflow jobs drain <JOB_ID> --region=<region>
#
# 5. CANCEL (stop immediately, may drop in-flight messages):
#    gcloud dataflow jobs cancel <JOB_ID> --region=<region>
#
# 6. Verify no active jobs:
#    gcloud dataflow jobs list --region=<region> --status=active
#
# Key lessons from deployment:
#   - All Beam transform functions must be self-contained (import inside fn).
#   - Module-level globals (constants, imports) cause NameError on workers.
#   - Clear the GCS staging path before relaunching: gcs rm -r gs://<bucket>/dataflow/
#   - Use dill.loads(dill.dumps(fn)) to test serialization before spending credits.
#
# ─────────────────────────────────────────────────────────────────────────────
# DATAPROC — PySpark battery health batch job (Phase 5)
# ─────────────────────────────────────────────────────────────────────────────
#
# IMPORTANT: Delete the cluster immediately after the job completes.
# A running Dataproc cluster (e2-standard-2) bills ~$0.07/hour.
#
# 1. Upload the PySpark script to GCS:
#    gcloud storage cp spark/battery_health.py \
#      gs://<bucket>/spark/battery_health.py
#
# 2. Create a single-node cluster (choose an available zone):
#    gcloud dataproc clusters create ev-spark \
#      --project=<project_id> \
#      --region=<region> \
#      --zone=asia-south1-b \
#      --single-node \
#      --master-machine-type=e2-standard-2 \
#      --master-boot-disk-size=50GB \
#      --image-version=2.1-debian11 \
#      --properties=spark:spark.jars.packages=com.google.cloud.spark:spark-bigquery-with-dependencies_2.12:0.34.0
#
# 3. Submit the PySpark job:
#    gcloud dataproc jobs submit pyspark \
#      gs://<bucket>/spark/battery_health.py \
#      --cluster=ev-spark \
#      --region=<region> \
#      -- \
#      --project=<project_id> \
#      --bucket=<bucket_name>
#
# 4. DELETE THE CLUSTER IMMEDIATELY after the job finishes:
#    gcloud dataproc clusters delete ev-spark --region=<region>
#
# 5. Verify deletion:
#    gcloud dataproc clusters list --region=<region>
#
# =============================================================================
