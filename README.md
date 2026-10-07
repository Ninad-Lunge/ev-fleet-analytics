# EV Fleet Analytics & Predictive Maintenance Platform

A project-driven GCP Data Engineering capstone. Every GCP data service is learned
when the project requires it — not as isolated topic drills.

**Domain:** You are the data engineer for an EV company with a (nominal) fleet of
10,000 vehicles emitting telemetry. This platform implements the full data
engineering lifecycle: ingestion, data lake, warehouse, streaming, batch, ML, and
full orchestration — all on GCP, all automated.

> **Volume rule:** keep the *narrative* at 10,000 vehicles but the *actual* dataset
> small so everything stays within free-tier limits.

---

<img width="2026" height="886" alt="ev-fleet-analytics_drawio-Animation" src="https://github.com/user-attachments/assets/1f35fb5f-e87e-47af-8d9d-f104ffcaddb4" />


## Architecture

```
                  DAILY AUTOMATED PIPELINE
                  ─────────────────────────

Cloud Scheduler (01:00 IST)          Cloud Scheduler (02:00 IST)
        │                                      │
        ▼                                      ▼
Cloud Run Job (ev-generator)        Cloud Workflows (ev-nightly-pipeline)
writes date=today/ Parquet           7-step orchestrated DAG:
        │                              1. Trigger ingestion
        ▼                              2. Refresh warehouse (parallel)
Cloud Storage (data lake)              3. SQL enrichment (anomaly flags)
  raw/telemetry/date=YYYY-MM-DD/       4. ML feature table refresh
        │                              5. Retrain BQML model
        ├─── External table ───────►   6. Refresh predictions
        │    (Hive partitioned)         7. Anomaly alert query
        │
        └─── Native table ─────────► BigQuery star schema
             PARTITION + CLUSTER         fact_telemetry
                                         dim_vehicle
                                         battery_health_spark (Spark)
                                         ml_features
                                         battery_anomaly_model (BQML)
                                         predictions


  REAL-TIME STREAMING (Phase 4)
  ─────────────────────────────

ev-stream-publish (local) ──► Pub/Sub topic (ev-telemetry)
                                    │
              ┌─────────────────────┤
              │                     │
              ▼                     ▼
  ev-telemetry-bq             ev-telemetry-beam
  (BQ subscription,           (pull subscription,
   always-on,                  consumed by Dataflow
   → telemetry_stream)         → telemetry_enriched)


  ON-DEMAND BATCH (Phase 5)
  ─────────────────────────

GCS raw/telemetry/ ──► Dataproc (PySpark) ──► battery_health_spark
                        single-node cluster     (delete after job)
```

---

## Repository layout

```
ev-fleet-analytics/
│
├── src/ev_fleet/                   Python package (Phase 1–3)
│   ├── schema.py                   TelemetryRecord + PyArrow schema
│   ├── generator/
│   │   ├── config.py               GeneratorConfig (validated, reproducible)
│   │   └── telemetry.py            Per-vehicle state machine DRIVING/CHARGING/IDLE
│   ├── lake/
│   │   ├── layout.py               Hive-partitioned path layout
│   │   ├── writer.py               Local Parquet writer + GCS upload
│   │   └── reader.py               Read partitioned lake back into DataFrame
│   ├── streaming/
│   │   └── publisher.py            Pub/Sub publisher (rate-limited, limit-capped)
│   └── cli/
│       ├── generate.py             ev-generate  — batch ingestion CLI
│       └── stream_publish.py       ev-stream-publish — streaming simulator CLI
│
├── tests/
│   ├── test_pipeline.py            Offline: determinism, plausibility, Parquet output
│   └── test_streaming.py           Offline: JSON serialization, publish limit
│
├── dataflow/                       Phase 4b — Apache Beam pipeline
│   ├── telemetry_pipeline.py       Beam: ReadFromPubSub → enrich → WriteToBigQuery
│   ├── transforms.py               Pure transform logic (Beam-free, testable offline)
│   ├── requirements.txt            apache-beam[gcp]==2.60.0 (Python 3.12, no-build-isolation)
│   └── README.md                   Launch, monitor, and DRAIN runbook
│
├── spark/                          Phase 5 — PySpark batch job
│   └── battery_health.py           Per-vehicle health metrics: GCS → Dataproc → BigQuery
│
├── workflows/                      Phase 7 — Orchestration
│   └── nightly_pipeline.yaml.tftpl Terraform templatefile — rendered portable by TF
│
├── sql/                            Phase 2, 5, 6 — SQL scripts
│   ├── phase2_schema.sql           BigQuery DDL (datasets, tables, external table)
│   ├── phase2_analytics.sql        5 business-question queries with explanations
│   └── phase5_phase6.sql           ML feature table, BQML model, ML.PREDICT
│
├── terraform/                      IaC — full platform as code
│   ├── versions.tf                 Provider pins, commented GCS backend
│   ├── variables.tf                17 variables with validation blocks
│   ├── terraform.tfvars.example    Safe template (commit this, not tfvars)
│   ├── main.tf                     Root: 8 module calls, locals, cross-module wiring
│   ├── outputs.tf                  18 outputs for CI/CD
│   ├── .gitignore                  Blocks state + tfvars from git
│   └── modules/
│       ├── storage/                GCS bucket + lifecycle rules + staging placeholder
│       ├── iam/                    All SAs + every IAM binding in one place
│       ├── bigquery/               2 datasets + 7 tables + external table
│       ├── ingestion/              Artifact Registry + Cloud Run Job + Scheduler 01:00
│       ├── workflows/              Cloud Workflow (templatefile) + Scheduler 02:00
│       ├── pubsub/                 Topic + BQ subscription + Beam pull subscription
│       ├── monitoring/             4 alert policies (pipeline, backlog, gap, job failure)
│       └── streaming/              Dataflow + Dataproc as locals/runbook (ephemeral)
│
├── architecture.svg                Full architecture diagram (open in any browser)
├── pyproject.toml                  Package config: deps, extras, CLI entry points
├── requirements.txt                Core deps for plain pip
└── Dockerfile / .dockerignore      Container image for Cloud Run Job
```

---

## Phases implemented

| Phase | What was built | GCP services |
|-------|---------------|-------------|
| 1 | Data lake: synthetic generator → Parquet → GCS | Cloud Storage |
| 2 | Warehouse: star schema, analytics SQL, partition pruning | BigQuery |
| 3 | Automated ingestion: containerized, scheduled, least-privilege SA | Artifact Registry, Cloud Run, Cloud Scheduler |
| 4a | Always-on streaming ingestion | Pub/Sub → BigQuery subscription |
| 4b | Stream enrichment with anomaly detection | Pub/Sub → Dataflow (Beam) |
| 5 | Historical batch processing | Managed Service for Apache Spark (formerly Dataproc) |
| 6 | In-warehouse ML: feature engineering, training, prediction | BigQuery ML |
| 7 | Full orchestration + data quality alerts + IaC | Cloud Workflows, Cloud Monitoring, Terraform |

---

## Telemetry schema

```
vehicle_id, timestamp, latitude, longitude,
battery_soc, battery_voltage, battery_temperature, motor_temperature,
speed, odometer, charging_status, power_consumption
```

Each vehicle is a state machine (DRIVING / CHARGING / IDLE). SOC drains while
driving, rises while charging (power goes negative), temperatures track load. This
makes analytics and anomaly detection meaningful rather than random noise.

---

## Install

```bash
python -m venv .venv && source .venv/bin/activate

# Core + dev tooling (Phases 1–4)
pip install -e ".[dev]"

# GCS upload support (Phase 1–3)
pip install -e ".[gcs,dev]"

# Pub/Sub streaming (Phase 4)
pip install -e ".[pubsub,dev]"

# Apache Beam / Dataflow (Phase 4b) — separate venv, Python 3.12 only
python3.12 -m venv .beam-venv
.beam-venv/bin/pip install "setuptools<81" wheel
.beam-venv/bin/pip install --no-build-isolation "apache-beam[gcp]==2.60.0"
```

---

## Quick start

### Generate + upload data (Phase 1)

```bash
# Authenticate
gcloud auth application-default login

# Generate 100 vehicles, 1 day, 5-min intervals → upload to GCS
ev-generate --vehicles 100 --days 1 --interval 300 \
  --output data/lake \
  --bucket <your-bucket>

# Generate for today's date (used by Cloud Run Job in production)
ev-generate --today --vehicles 100 --days 1 --interval 300 \
  --output /tmp/lake --bucket <your-bucket>
```

### Stream telemetry to Pub/Sub (Phase 4a/4b)

```bash
source .venv/bin/activate

ev-stream-publish \
  --project <project-id> \
  --topic ev-telemetry \
  --vehicles 20 --rate 20 --limit 500
```

### Run the Dataflow enrichment pipeline (Phase 4b)

See `dataflow/README.md` for the full launch + DRAIN runbook.
**Always drain the job after testing — it bills per VM/second.**

### Run the PySpark batch job (Phase 5)

```bash
# Upload script
gcloud storage cp spark/battery_health.py gs://<bucket>/spark/

# Create single-node cluster
gcloud dataproc clusters create ev-spark \
  --region=asia-south1 --zone=asia-south1-b --single-node \
  --master-machine-type=e2-standard-2 --image-version=2.1-debian11 \
  --properties=spark:spark.jars.packages=com.google.cloud.spark:spark-bigquery-with-dependencies_2.12:0.34.0

# Submit job
gcloud dataproc jobs submit pyspark gs://<bucket>/spark/battery_health.py \
  --cluster=ev-spark --region=asia-south1 \
  -- --project=<project-id> --bucket=<bucket>

# DELETE cluster immediately after
gcloud dataproc clusters delete ev-spark --region=asia-south1
```

---

## Prerequisites (new GCP project)

Before running `terraform apply` on a fresh project, complete these steps once.
Terraform cannot enable APIs or create the project itself.

### 1. Create and configure the project

```bash
# Set your new project as active
gcloud config set project <your-project-id>

# Update Application Default Credentials to use the new project for quota
gcloud auth application-default login
gcloud auth application-default set-quota-project <your-project-id>
```

### 2. Link billing

GCP Console → Billing → My Projects → link your billing account.
Without billing, Cloud Run, Workflows, and Scheduler will be blocked.

### 3. Enable required APIs

Terraform manages resources but cannot enable APIs. Run this once per new project:

```bash
gcloud services enable \
  cloudresourcemanager.googleapis.com \
  iam.googleapis.com \
  storage.googleapis.com \
  bigquery.googleapis.com \
  run.googleapis.com \
  cloudscheduler.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  pubsub.googleapis.com \
  workflows.googleapis.com \
  workflowexecutions.googleapis.com \
  monitoring.googleapis.com \
  logging.googleapis.com \
  dataflow.googleapis.com \
  dataproc.googleapis.com \
  --project=<your-project-id>
```

| API | Used by |
|-----|---------|
| `cloudresourcemanager` | Terraform IAM bindings |
| `iam` | Service account creation |
| `storage` | GCS data lake bucket |
| `bigquery` | All warehouse tables |
| `run` | Cloud Run ingestion job |
| `cloudscheduler` | Automated cron triggers |
| `artifactregistry` | Container image storage |
| `cloudbuild` | Building the container image |
| `pubsub` | Real-time telemetry streaming |
| `workflows` | Nightly pipeline orchestration |
| `workflowexecutions` | Triggering workflow runs |
| `monitoring` | Alert policies |
| `logging` | Log-based metric for data quality alert |
| `dataflow` | Beam enrichment pipeline (Phase 4b) |
| `dataproc` | Managed Service for Apache Spark (Phase 5) |

### 4. Find your project number

The `project_number` variable is required for constructing Pub/Sub and Cloud Run
service-agent email addresses. It is the numeric ID, not the project ID string.

```bash
gcloud projects describe <your-project-id> --format='value(projectNumber)'
```

---

## Terraform — deploy to any GCP project

The entire platform is codified as Terraform. All project-specific values are
variables — no hardcoded IDs, bucket names, or emails anywhere. Complete the
Prerequisites section above first.

> **Ordering matters.** The deployment has dependencies that Terraform cannot
> resolve automatically because they span the boundary between infrastructure
> and data. Follow the steps below in order.

### Step 1 — Fill in tfvars

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`. Minimum required fields:

| Variable | Example | Notes |
|---|---|---|
| `project_id` | `ev-fleet-analytics-test` | GCP project ID (not number) |
| `project_number` | `448453438636` | From `gcloud projects describe` |
| `bucket_name` | `ev-fleet-lake-<project-id>` | Must be globally unique across all GCP |
| `container_image` | `asia-south1-docker.pkg.dev/<project>/ev-fleet/ev-generator:v1` | Built in Step 3 |
| `alert_notification_email` | `your@email.com` | For Cloud Monitoring alerts |

### Step 2 — Deploy infrastructure with Terraform

```bash
terraform init
terraform plan    # review: ~44 resources to create
terraform apply
```

This creates: GCS bucket, BigQuery datasets + tables, IAM service accounts +
bindings, Artifact Registry repo, Cloud Run job, Cloud Scheduler (×2), Cloud
Workflow, Pub/Sub topic + subscriptions, Cloud Monitoring alerts.

> **Known: Workflows service agent delay.** If `terraform apply` fails with
> "Workflows service agent does not exist", wait 30 seconds and re-run
> `terraform apply`. This is a GCP propagation delay when the Workflows API
> is enabled for the first time.

### Step 3 — Build and push the container image

The Artifact Registry repo now exists. Build the image:

```bash
cd ..   # back to ev-fleet-analytics/
gcloud builds submit \
  --tag asia-south1-docker.pkg.dev/<your-project-id>/ev-fleet/ev-generator:v1 \
  --project=<your-project-id>
```

> **Why Step 3 comes after Step 2:** Cloud Run validates the image exists in
> Artifact Registry when the job is created. The registry must exist (created
> by Terraform) before the image can be pushed. The image must exist before
> the first workflow run.

### Step 4 — Seed the data lake

The BigQuery external table and the ML model both need data to function.
Generate a minimum viable dataset before running the workflow:

```bash
# Activate the Python venv (install first if needed: pip install -e ".[gcs]")
source .venv/bin/activate

# Generate 50 vehicles × 7 days — minimum for the ML model to get both
# TRUE and FALSE labels from the p95 threshold. Fewer vehicles or days
# produces a single-class label and BQML will refuse to train.
ev-generate \
  --vehicles 50 \
  --days 7 \
  --interval 3600 \
  --start-date $(date -u -v-7d +%Y-%m-%d 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%d) \
  --output /tmp/lake \
  --bucket <your-bucket-name>
```

> **Why this step exists:**
> - The BigQuery external table (`ev_raw.telemetry_ext`) validates the GCS
>   source URI on creation. It will fail if the bucket is empty.
> - The BQML logistic regression requires at least 2 unique label values.
>   With <50 vehicles the p95 threshold may produce all-FALSE or all-TRUE
>   labels, causing the model training step to fail.

### Step 5 — Trigger the pipeline and validate

```bash
gcloud workflows run ev-nightly-pipeline \
  --location=asia-south1 \
  --project=<your-project-id>
```

The workflow takes ~3–4 minutes. Verify all outputs:

```bash
# Warehouse populated
bq query --use_legacy_sql=false \
  "SELECT COUNT(*) AS rows, COUNT(DISTINCT event_date) AS days
   FROM \`<project>.ev_analytics.fact_telemetry\`"

# ML features with balanced labels (expect ~95% false, ~5% true)
bq query --use_legacy_sql=false \
  "SELECT is_anomaly, COUNT(*) AS cnt
   FROM \`<project>.ev_analytics.ml_features\` GROUP BY 1"

# Predictions scored
bq query --use_legacy_sql=false \
  "SELECT COUNT(*) AS vehicles, MAX(anomaly_probability) AS max_prob
   FROM \`<project>.ev_analytics.predictions\`
   WHERE event_date = CURRENT_DATE('Asia/Kolkata')"
```

### Step 6 — Enable post-deployment monitoring alerts (optional)

Two alert policies are commented out in `modules/monitoring/main.tf` because
the Cloud Monitoring API rejects them on a fresh project (their metrics don't
exist until the pipeline has run):

- `workflow_failed` — requires `workflowexecutions.googleapis.com` metric,
  registered after the first workflow execution.
- `telemetry_gap` — requires the log-based metric to have received at least
  one matching log entry.

After Step 5 succeeds, uncomment both resources in `modules/monitoring/main.tf`
and run `terraform apply` again.

---

### Deployment summary

```
Step 1: fill terraform.tfvars
Step 2: terraform apply          → infrastructure deployed (~2 min)
Step 3: gcloud builds submit     → container image built and pushed
Step 4: ev-generate              → data lake seeded (50 vehicles, 7 days)
Step 5: gcloud workflows run     → full pipeline validated end-to-end (~3 min)
Step 6: uncomment alerts + apply → monitoring fully operational (optional)
```

The Cloud Workflows YAML is a Terraform `templatefile` (`.tftpl`). All
project-specific values (project ID, region, bucket name) are injected at
`apply` time — the YAML contains no hardcoded values and deploys cleanly
to any GCP project.

For shared/team use, uncomment the GCS backend block in `versions.tf` first.

---

## Testing

```bash
# Core pipeline tests (offline, no GCP)
pytest

# Streaming tests (offline, fake publisher)
pytest tests/test_streaming.py

# Dataflow transform logic (offline, no Beam install needed)
cd dataflow && python - <<'EOF'
from transforms import parse_message, enrich
import json
r = parse_message(json.dumps({"vehicle_id":"EV-0001","timestamp":"2026-09-22T00:00:00+00:00",
  "battery_temperature":30.0,"motor_temperature":50.0,"battery_soc":80.0,
  "speed":40.0,"charging_status":False,"power_consumption":18.0}).encode())
print(enrich(r))
EOF
```

---

## IAM — least-privilege design

| Service account | Scope | Permissions |
|----------------|-------|-------------|
| `ev-ingest-runner` | bucket-level only | `storage.objectCreator` (create, not read/delete) |
| `ev-ingest-runner` | job-level only | `run.invoker` on `ev-generator` job only |
| `ev-workflow-runner` | project-level | `bigquery.jobUser`, `bigquery.dataEditor`, `logging.logWriter`, `run.invoker`, `workflows.invoker` |
| `ev-workflow-runner` | bucket-level | `storage.objectViewer` (needed by BQ external table glob) |

No service account has project-wide storage admin or BigQuery admin. The Compute
Engine default SA holds only the minimum roles for Cloud Build, Dataflow, and
Dataproc workers.
