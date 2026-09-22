# Phase 4b - Dataflow / Beam streaming pipeline

Reads EV telemetry from a Pub/Sub subscription, validates, enriches with anomaly
flags, and writes to `ev_raw.telemetry_enriched` in BigQuery. This is the
transformation a plain Pub/Sub -> BigQuery subscription (Phase 4a) cannot do.

```
Pub/Sub subscription --> parse JSON --> drop invalid --> flag anomalies --> BigQuery
```

## ⚠️ COST WARNING - READ FIRST

Dataflow runs continuous worker VMs and **does not stop itself**. A forgotten
streaming job burns credits 24/7. Always:

1. Launch with a **single small worker** (`--num_workers=1 --max_num_workers=1
   --machine_type=e2-small`).
2. **DRAIN or CANCEL** the job the moment testing is done.
3. Never leave a streaming job running unattended.

## Setup

```bash
python -m venv .beam-venv
source .beam-venv/bin/activate
pip install -r dataflow/requirements.txt
```

## A pull subscription for the pipeline

The Beam `ReadFromPubSub` needs its own subscription (separate from the 4a BigQuery
subscription). Create one:

```bash
gcloud pubsub subscriptions create ev-telemetry-beam \
  --topic ev-telemetry \
  --project project-623b2045-f641-41e7-894
```

## Run on Dataflow (tiny worker)

```bash
PROJECT=project-623b2045-f641-41e7-894
BUCKET=ev-fleet-lake-project-ninad
REGION=asia-south1

python dataflow/telemetry_pipeline.py \
  --runner=DataflowRunner \
  --project=$PROJECT \
  --region=$REGION \
  --temp_location=gs://$BUCKET/dataflow/temp \
  --staging_location=gs://$BUCKET/dataflow/staging \
  --subscription=projects/$PROJECT/subscriptions/ev-telemetry-beam \
  --output_table=$PROJECT:ev_raw.telemetry_enriched \
  --num_workers=1 \
  --max_num_workers=1 \
  --machine_type=e2-small \
  --job_name=ev-telemetry-enrich
```

## Feed it data (in another terminal)

```bash
ev-stream-publish --project $PROJECT --topic ev-telemetry \
  --vehicles 20 --rate 30 --limit 1000
```

## TEARDOWN (do this immediately after verifying output)

```bash
REGION=asia-south1
# find the running job id
gcloud dataflow jobs list --region=$REGION --status=active
# drain (finishes in-flight data) or cancel (stops immediately)
gcloud dataflow jobs drain <JOB_ID> --region=$REGION
# confirm no active jobs remain
gcloud dataflow jobs list --region=$REGION --status=active
```

## Local test (DirectRunner, no Dataflow, no cost)

You can validate the transform logic locally without launching Dataflow by running
the `parse_message` / `enrich` functions directly (see the pipeline module). This is
the cheapest way to iterate on the logic before spending any credits.
