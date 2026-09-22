# modules/ingestion/main.tf
#
# Artifact Registry repository, Cloud Run Job, and Cloud Scheduler trigger
# for the daily telemetry ingestion.

# =============================================================================
# ARTIFACT REGISTRY
# Stores the ev-generator container image. Using Artifact Registry instead of
# Container Registry (gcr.io) because: location-specific (no global redirect),
# supports vulnerability scanning, and Container Registry was shut down March 2025.
# =============================================================================

resource "google_artifact_registry_repository" "ev_fleet" {
  project       = var.project_id
  location      = var.region
  repository_id = "ev-fleet"
  format        = "DOCKER"
  description   = "Docker images for the EV Fleet Analytics platform. Built by Cloud Build, pulled by Cloud Run."

  labels = {
    environment = var.environment
    managed-by  = "terraform"
  }
}

# =============================================================================
# CLOUD RUN JOB
# Runs the ev-generate CLI to completion (batch semantics, not a service).
# Cloud Run Job is the correct primitive here: a service is for long-lived
# HTTP listeners, a job is for finite batch tasks.
# =============================================================================

resource "google_cloud_run_v2_job" "ev_generator" {
  project  = var.project_id
  location = var.region
  name     = "ev-generator"

  template {
    template {
      # Run as the least-privilege ingestion SA — not the Compute default SA.
      service_account = var.ingest_sa_email

      max_retries = 1 # retry once on transient failure; fail fast after that

      containers {
        image = var.container_image

        # CLI args passed to the ev-generate entrypoint.
        # --today stamps the current UTC date so each run creates a fresh partition.
        # tostring() required because Cloud Run args must all be strings.
        args = [
          "--today",
          "--vehicles", tostring(var.vehicles_per_run),
          "--days",     "1",
          "--interval", tostring(var.interval_seconds),
          "--output",   "/tmp/lake",   # ephemeral container filesystem
          "--bucket",   var.bucket_name,
        ]

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }
      }

      timeout = "600s" # 10-minute hard limit per task attempt
    }
  }

  labels = {
    environment = var.environment
    managed-by  = "terraform"
  }

  # Ignore changes to the image so Terraform does not try to recreate the job
  # every time a new image is pushed via Cloud Build (outside Terraform's scope).
  # The image is updated via `gcloud run jobs update` or a CI pipeline step.
  lifecycle {
    ignore_changes = [
      template[0].template[0].containers[0].image,
    ]
  }
}

# =============================================================================
# CLOUD SCHEDULER — ingestion trigger
# Fires at 01:00 IST daily to run the Cloud Run job.
# Uses the REGIONAL Cloud Run API endpoint (not the global one) — the global
# endpoint returns NOT_FOUND for regional jobs.
# =============================================================================

resource "google_cloud_scheduler_job" "ev_ingest_daily" {
  project   = var.project_id
  region    = var.region
  name      = "ev-ingest-daily"
  schedule  = var.ingestion_cron
  time_zone = var.scheduler_timezone
  paused    = false

  http_target {
    http_method = "POST"
    # Regional Cloud Run Jobs run API — must match the job's region.
    uri = "https://${var.region}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${var.project_id}/jobs/${google_cloud_run_v2_job.ev_generator.name}:run"

    oauth_token {
      # The scheduler authenticates as the ingestion SA, which has run.invoker
      # on this specific job.
      service_account_email = var.ingest_sa_email
    }
  }

  depends_on = [google_cloud_run_v2_job.ev_generator]
}
