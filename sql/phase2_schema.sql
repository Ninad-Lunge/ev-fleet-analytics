-- =============================================================================
-- Phase 2 - EV Fleet Analytics: warehouse schema (DDL)
-- =============================================================================
-- Reproduces the BigQuery objects built in Phase 2, in dependency order.
-- Location: all datasets are in asia-south1 (must match the GCS bucket region).
--
-- Datasets (create via `bq mk`, NOT DDL - BigQuery has no CREATE SCHEMA here):
--   bq --location=asia-south1 mk --dataset PROJECT:ev_raw
--   bq --location=asia-south1 mk --dataset PROJECT:ev_analytics
--
-- The external table is created via `bq mkdef` + `bq mk` (Hive partitioning),
-- shown as a comment below because it is not expressible as portable DDL.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. External table over the GCS data lake, WITH Hive partitioning.
--    (CLI form - run in a shell, not as SQL.)
--
--    BUCKET=ev-fleet-lake-project-ninad
--    bq mkdef \
--      --source_format=PARQUET \
--      --hive_partitioning_mode=AUTO \
--      --hive_partitioning_source_uri_prefix=gs://$BUCKET/raw/telemetry/ \
--      "gs://$BUCKET/raw/telemetry/*" > /tmp/telemetry_ext_def.json
--    bq mk --table --external_table_definition=/tmp/telemetry_ext_def.json \
--      PROJECT:ev_raw.telemetry_ext
--
--    Key point: the Hive source-uri-prefix ends right BEFORE the `date=` folder,
--    so BigQuery derives a `date` partition column from the directory name. That
--    `date` column is a reserved word, so it must be backticked in queries; we
--    rename it to `event_date` when materializing native tables below.
-- -----------------------------------------------------------------------------


-- -----------------------------------------------------------------------------
-- 2. Native, partitioned + clustered table in the raw layer.
--    CTAS from the external table; renames `date` -> `event_date`.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `project-623b2045-f641-41e7-894.ev_raw.telemetry`
PARTITION BY event_date
CLUSTER BY vehicle_id
AS
SELECT
  vehicle_id,
  timestamp,
  latitude,
  longitude,
  battery_soc,
  battery_voltage,
  battery_temperature,
  motor_temperature,
  speed,
  odometer,
  charging_status,
  power_consumption,
  `date` AS event_date
FROM `project-623b2045-f641-41e7-894.ev_raw.telemetry_ext`;


-- -----------------------------------------------------------------------------
-- 3. Dimension: dim_vehicle.
--    Master data does not exist in telemetry, so we SYNTHESIZE it deterministically
--    from the vehicle_id suffix (MOD cycling). In production this table would be
--    loaded from a fleet-registry source instead.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `project-623b2045-f641-41e7-894.ev_analytics.dim_vehicle`
AS
WITH vehicles AS (
  SELECT DISTINCT vehicle_id
  FROM `project-623b2045-f641-41e7-894.ev_raw.telemetry`
),
enriched AS (
  SELECT
    vehicle_id,
    SAFE_CAST(REGEXP_EXTRACT(vehicle_id, r'(\d+)$') AS INT64) AS vnum
  FROM vehicles
)
SELECT
  vehicle_id,
  ['Model A', 'Model B', 'Model C', 'Model D'][OFFSET(MOD(vnum, 4))] AS model,
  2019 + MOD(vnum, 6) AS manufacture_year,
  [40.0, 60.0, 75.0, 90.0][OFFSET(MOD(vnum, 4))] AS battery_capacity_kwh,
  ['north', 'south', 'east', 'west'][OFFSET(MOD(vnum, 4))] AS fleet,
  ['Maharashtra', 'Karnataka', 'Tamil Nadu', 'Gujarat'][OFFSET(MOD(vnum, 4))] AS region
FROM enriched;


-- -----------------------------------------------------------------------------
-- 4. Fact: fact_telemetry (one row per reading).
--    Partitioned by event_date, clustered by vehicle_id (the join / filter key).
--    latitude/longitude are kept as continuous measures, not a dimension key;
--    a dim_location would be introduced later alongside charging-station events.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `project-623b2045-f641-41e7-894.ev_analytics.fact_telemetry`
PARTITION BY event_date
CLUSTER BY vehicle_id
AS
SELECT
  vehicle_id,
  timestamp,
  event_date,
  battery_soc,
  battery_voltage,
  battery_temperature,
  motor_temperature,
  speed,
  odometer,
  power_consumption,
  charging_status,
  latitude,
  longitude
FROM `project-623b2045-f641-41e7-894.ev_raw.telemetry`;
