-- =============================================================================
-- Phase 2 - EV Fleet Analytics: business-question queries
-- =============================================================================
-- Target: BigQuery (Standard SQL), dataset `ev_analytics` in asia-south1.
-- Star schema:
--     fact_telemetry (one row per reading; partitioned by event_date,
--                     clustered by vehicle_id)
--     dim_vehicle    (one row per vehicle; synthesized master data)
--
-- Reusability: replace the project id below if you clone this into another
-- project. All queries assume the tables created in Phase 2.
--
-- Lessons captured in comments:
--   * `date`, `rows`, `timestamp` are RESERVED WORDS in BigQuery. Avoid them as
--     aliases or backtick them. (We renamed the Hive `date` key to `event_date`.)
--   * Anomaly thresholds must match the data's real distribution. A fixed
--     ">45 C" threshold found nothing because this dataset tops out at ~40.6 C;
--     a percentile-based (p95) threshold is more robust.
--   * Sign convention: power_consumption is kW; NEGATIVE while charging (energy
--     flowing INTO the pack), POSITIVE while driving.
--   * Interval energy: each reading covers one sampling interval. For a 5-minute
--     (300s) interval, energy_kWh = power_kW * (300/3600).
-- =============================================================================

-- Set once; used throughout. (BigQuery has no \set; edit the fully-qualified
-- names below if your project id differs.)
--   project: project-623b2045-f641-41e7-894
--   dataset: ev_analytics


-- -----------------------------------------------------------------------------
-- Q1: Which vehicles consumed the most energy? (top 5)
-- Technique: SUM with GREATEST to count only positive (driving) draw; kW -> kWh
--            unit conversion; fact -> dim join for the model label.
-- -----------------------------------------------------------------------------
SELECT
  f.vehicle_id,
  d.model,
  ROUND(SUM(GREATEST(f.power_consumption, 0) * (300 / 3600)), 2) AS energy_kwh
FROM `project-623b2045-f641-41e7-894.ev_analytics.fact_telemetry` AS f
JOIN `project-623b2045-f641-41e7-894.ev_analytics.dim_vehicle` AS d
  USING (vehicle_id)
GROUP BY f.vehicle_id, d.model
ORDER BY energy_kwh DESC
LIMIT 5;


-- -----------------------------------------------------------------------------
-- Q2: Which vehicles have abnormal battery temperatures?
-- Technique: data-driven threshold via APPROX_QUANTILES (fleet p95) instead of a
--            fixed "magic number", combined with COUNTIF conditional aggregation.
-- Note: a naive "WHERE battery_temperature > 45" returns nothing on this dataset;
--       always sanity-check thresholds against the actual distribution first:
--         SELECT MIN(...), AVG(...),
--                APPROX_QUANTILES(battery_temperature,100)[OFFSET(95)], MAX(...)
--         FROM fact_telemetry;
-- -----------------------------------------------------------------------------
WITH threshold AS (
  SELECT APPROX_QUANTILES(battery_temperature, 100)[OFFSET(95)] AS p95
  FROM `project-623b2045-f641-41e7-894.ev_analytics.fact_telemetry`
)
SELECT
  f.vehicle_id,
  COUNTIF(f.battery_temperature > t.p95) AS readings_above_p95,
  ROUND(MAX(f.battery_temperature), 2) AS max_batt_temp
FROM `project-623b2045-f641-41e7-894.ev_analytics.fact_telemetry` AS f
CROSS JOIN threshold AS t
GROUP BY f.vehicle_id
HAVING readings_above_p95 > 0
ORDER BY readings_above_p95 DESC
LIMIT 5;


-- -----------------------------------------------------------------------------
-- Q3: Average battery metrics by vehicle model.
-- Technique: fact -> dim join, GROUP BY a dimension attribute.
-- -----------------------------------------------------------------------------
SELECT
  d.model,
  ROUND(AVG(f.battery_soc), 2) AS avg_soc,
  ROUND(AVG(f.battery_temperature), 2) AS avg_batt_temp,
  ROUND(AVG(f.battery_voltage), 2) AS avg_voltage
FROM `project-623b2045-f641-41e7-894.ev_analytics.fact_telemetry` AS f
JOIN `project-623b2045-f641-41e7-894.ev_analytics.dim_vehicle` AS d
  USING (vehicle_id)
GROUP BY d.model
ORDER BY d.model;


-- -----------------------------------------------------------------------------
-- Q4: Charging behavior per vehicle (time plugged in + energy charged).
-- Technique: boolean filtering with COUNTIF; sign convention (negate the
--            negative charging power to get positive energy INTO the pack).
-- -----------------------------------------------------------------------------
SELECT
  vehicle_id,
  COUNTIF(charging_status) AS charging_intervals,
  ROUND(COUNTIF(charging_status) * 5 / 60, 2) AS charging_hours,
  ROUND(SUM(IF(charging_status, -power_consumption, 0)) * (300 / 3600), 2)
    AS energy_charged_kwh
FROM `project-623b2045-f641-41e7-894.ev_analytics.fact_telemetry`
GROUP BY vehicle_id
ORDER BY energy_charged_kwh DESC
LIMIT 5;


-- -----------------------------------------------------------------------------
-- Q5: Average state-of-charge (SOC) at the moment a charging session begins.
-- Technique: LAG() window function to detect the transition from
--            charging_status = FALSE -> TRUE (a session START).
-- Insight: on this dataset the answer (~20.6%) recovers the simulator's
--          charge-trigger rule (start charging at SOC = 20%), demonstrating that
--          correct analytics can validate the source system's behavior.
-- -----------------------------------------------------------------------------
WITH flagged AS (
  SELECT
    vehicle_id,
    timestamp,
    battery_soc,
    charging_status,
    LAG(charging_status) OVER (
      PARTITION BY vehicle_id ORDER BY timestamp
    ) AS prev_charging
  FROM `project-623b2045-f641-41e7-894.ev_analytics.fact_telemetry`
),
session_starts AS (
  -- A session starts when this row is charging but the previous row was not
  -- (or there is no previous row, i.e. the series opens mid-charge).
  SELECT vehicle_id, timestamp, battery_soc
  FROM flagged
  WHERE charging_status = TRUE
    AND (prev_charging = FALSE OR prev_charging IS NULL)
)
SELECT
  COUNT(*) AS charging_sessions,
  ROUND(AVG(battery_soc), 2) AS avg_soc_at_charge_start,
  ROUND(MIN(battery_soc), 2) AS min_soc_at_charge_start,
  ROUND(MAX(battery_soc), 2) AS max_soc_at_charge_start
FROM session_starts;


-- Q5b: same idea, broken out per vehicle.
WITH flagged AS (
  SELECT
    vehicle_id,
    battery_soc,
    charging_status,
    LAG(charging_status) OVER (
      PARTITION BY vehicle_id ORDER BY timestamp
    ) AS prev_charging
  FROM `project-623b2045-f641-41e7-894.ev_analytics.fact_telemetry`
)
SELECT
  vehicle_id,
  COUNT(*) AS sessions,
  ROUND(AVG(battery_soc), 2) AS avg_soc_at_start
FROM flagged
WHERE charging_status = TRUE
  AND (prev_charging = FALSE OR prev_charging IS NULL)
GROUP BY vehicle_id
ORDER BY avg_soc_at_start;
