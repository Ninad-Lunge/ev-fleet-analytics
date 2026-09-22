# Container image for the EV telemetry generator, run as a Cloud Run Job.
#
# The job runs `ev-generate` to completion (it is a batch task, not a server), and
# writes a fresh date=<today> partition to the GCS data lake. Authentication uses
# the Cloud Run service account's Application Default Credentials at runtime - no
# keys are baked into the image.

# Slim, pinned base for small image size and reproducibility.
FROM python:3.12-slim

# Do not write .pyc files; stream stdout/stderr straight to the logs.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Install dependencies first (better layer caching), then the package itself.
# The [gcs] extra pulls in google-cloud-storage for the upload path.
COPY pyproject.toml requirements.txt README.md ./
COPY src ./src
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir ".[gcs]"

# Default command. Cloud Run Job args can OVERRIDE these at deploy/run time
# (e.g. change --vehicles or the --bucket). The defaults here describe a small
# daily run that lands one fresh partition for the current date.
#
# --today       : stamp the current UTC date (fresh date=<today> partition)
# --vehicles 100: small daily volume
# --days 1      : a single day per run
# --interval 300: 5-minute sampling
# --output      : ephemeral local scratch inside the container
# --bucket      : the data-lake bucket (override per environment)
ENTRYPOINT ["ev-generate"]
CMD ["--today", \
     "--vehicles", "100", \
     "--days", "1", \
     "--interval", "300", \
     "--output", "/tmp/lake", \
     "--bucket", "ev-fleet-lake-project-ninad"]
