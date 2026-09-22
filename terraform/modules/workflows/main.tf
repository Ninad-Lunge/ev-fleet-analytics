# modules/workflows/main.tf
#
# Cloud Workflows deployment and the Cloud Scheduler job that triggers it.
#
# PORTABILITY: The workflow YAML is a Terraform templatefile (.tftpl).
# All project-specific values (project_id, region, run_job name, etc.)
# are injected by templatefile() at plan/apply time. The template file
# itself contains no hardcoded values and can be deployed to any GCP
# project by changing terraform.tfvars only.
#
# Escaping convention in the template:
#   ${...}  → Terraform interpolation (replaced at apply time)
#   $${...} → escaped literal, becomes ${...} in the rendered YAML,
#             which is the Cloud Workflows expression syntax.

resource "google_workflows_workflow" "ev_nightly_pipeline" {
  project         = var.project_id
  region          = var.region
  name            = "ev-nightly-pipeline"
  service_account = var.workflow_sa_email
  description     = "Nightly EV Fleet Analytics pipeline: ingest → warehouse → enrich → ML features → retrain → predictions → alert."

  # Render the .tftpl template, substituting all project-specific values.
  # Any change to the template file or to these variables triggers a
  # workflow resource update on the next terraform apply.
  source_contents = templatefile(var.workflow_file_path, {
    project_id  = var.project_id
    region      = var.region
    bucket_name = var.bucket_name
    workflow_sa = var.workflow_sa_email
    run_job     = var.cloud_run_job_name
  })

  labels = {
    environment = var.environment
    managed-by  = "terraform"
  }

  # GCP may add internal labels; ignore them to avoid spurious plan diffs.
  lifecycle {
    ignore_changes = [labels]
  }
}

# Cloud Scheduler job that fires at 02:00 local time and triggers a new
# workflow execution via the Workflow Executions API.
resource "google_cloud_scheduler_job" "ev_pipeline_daily" {
  project   = var.project_id
  region    = var.region
  name      = "ev-pipeline-daily"
  schedule  = var.pipeline_cron
  time_zone = var.scheduler_timezone
  paused    = false

  http_target {
    http_method = "POST"
    uri         = "https://workflowexecutions.googleapis.com/v1/projects/${var.project_id}/locations/${var.region}/workflows/${google_workflows_workflow.ev_nightly_pipeline.name}/executions"

    # Cloud Scheduler expects a base64-encoded JSON body.
    body = base64encode(jsonencode({ argument = "{}" }))

    oauth_token {
      service_account_email = var.workflow_sa_email
    }
  }

  depends_on = [google_workflows_workflow.ev_nightly_pipeline]
}
