# versions.tf
# Pin Terraform and provider versions so every team member and CI pipeline
# runs against the same binary. Never use open ranges (">= X") for providers
# in production code — a provider bump can introduce breaking changes silently.

terraform {
  required_version = ">= 1.7"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.0"
    }
  }

  # ---------------------------------------------------------------------------
  # Remote state backend (GCS).
  # Uncomment and fill in before running `terraform init` in a shared environment.
  # Never store state locally on a dev machine for a shared platform.
  # ---------------------------------------------------------------------------
  # backend "gcs" {
  #   bucket = "<your-terraform-state-bucket>"
  #   prefix = "ev-fleet-analytics/terraform/state"
  # }
}

# ---------------------------------------------------------------------------
# Default provider configuration.
# Authentication uses Application Default Credentials (ADC): no credentials
# block is needed. Run `gcloud auth application-default login` once per machine.
# In CI, use Workload Identity Federation or a service account key mounted as
# GOOGLE_APPLICATION_CREDENTIALS — never commit a key file.
# ---------------------------------------------------------------------------
provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}
