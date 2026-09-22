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
| 5 | Historical batch processing | Dataproc (PySpark) |
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

## Terraform — deploy to any GCP project

The entire platform is codified as Terraform. All project-specific values are
variables — no hardcoded IDs, bucket names, or emails anywhere.

```bash
cd terraform

# 1. Copy and fill in the template
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars with your project_id, project_number, bucket_name, etc.

# 2. Initialise (downloads providers, reads module sources)
terraform init

# 3. Preview
terraform plan

# 4. Deploy
terraform apply
```

The Cloud Workflows YAML is a Terraform `templatefile` (`.tftpl`). Variables are
injected at `apply` time — the YAML contains no hardcoded values and deploys cleanly
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

---

## Key lessons learned (exam-relevant)

- **Partition pruning:** date-filtered queries scan 1/7th of data vs full scan — confirmed via `bq --dry_run`.
- **Clustering:** only reduces bytes at large per-partition volumes; no effect at small scale.
- **Beam self-contained functions:** all imports and constants must be inside the function body. Module-level globals cause `NameError` on remote Dataflow workers (dill serialization).
- **Regional API endpoints:** Cloud Scheduler → Cloud Run Jobs requires the regional endpoint (`asia-south1-run.googleapis.com`), not the global one (returns NOT_FOUND).
- **BigQuery ML vs custom models:** BQML keeps training, evaluation, and inference in SQL. No model server, no `.pkl` files, no deployment pipeline. Tradeoff: simpler ops, less model flexibility.
- **Dataflow vs BigQuery SQL for batch:** for daily enrichment at this scale, BigQuery SQL is the correct, cheaper choice. Dataflow is justified for streaming with windowing, exactly-once semantics, or complex non-SQL transforms.
- **Cloud Workflows vs Composer:** Composer runs a GKE cluster (~$300/month). Workflows is serverless, free ≤5,000 steps/month, and sufficient for a sequential DAG. Choose Composer when you need Airflow's sensor ecosystem or complex dependency graphs.
- **`_member` over `_binding` in Terraform:** additive vs authoritative IAM. `_binding` replaces the entire role member list and causes outages in shared projects.
