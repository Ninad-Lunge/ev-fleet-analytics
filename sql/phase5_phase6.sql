-- =============================================================================
-- Phase 5 & 6 - Dataproc/PySpark and BigQuery ML
-- =============================================================================
-- Phase 5 PySpark job is in spark/battery_health.py
-- This file contains:
--   1. BigQuery ML feature table creation
--   2. BQML LOGISTIC_REG model training
--   3. ML.EVALUATE
--   4. ML.PREDICT with ranked anomaly predictions
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Phase 6 Step 1: ML feature table
-- One row per vehicle per day. Label derived from data-driven p95 threshold on
-- daily max battery temperature (same pattern as Phase 2 Q2 anomaly detection).
-- This gives a realistic ~5% positive rate suitable for logistic regression.
--
-- Lesson: when a streaming pipeline produces all-negative labels (as Phase 4b
-- did here because the 38C threshold was never breached in this dataset), derive
-- the label from the features themselves using a percentile-based threshold
-- rather than forcing synthetic data into a broken pipeline.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `project-623b2045-f641-41e7-894.ev_analytics.ml_features`
AS
WITH daily AS (
  SELECT
    vehicle_id,
    event_date,
    ROUND(AVG(battery_soc), 2)         AS avg_soc,
    ROUND(MIN(battery_soc), 2)         AS min_soc,
    ROUND(AVG(battery_temperature), 2) AS avg_batt_temp,
    ROUND(MAX(battery_temperature), 2) AS max_batt_temp,
    ROUND(AVG(battery_voltage), 2)     AS avg_voltage,
    ROUND(STDDEV(battery_voltage), 4)  AS voltage_stddev,
    ROUND(AVG(motor_temperature), 2)   AS avg_motor_temp,
    ROUND(AVG(speed), 2)               AS avg_speed,
    ROUND(AVG(power_consumption), 3)   AS avg_power,
    ROUND(SUM(GREATEST(power_consumption, 0) * (300/3600)), 2) AS daily_energy_kwh,
    COUNTIF(charging_status)           AS charging_intervals,
    COUNT(*)                           AS reading_count
  FROM `project-623b2045-f641-41e7-894.ev_analytics.fact_telemetry`
  GROUP BY vehicle_id, event_date
),
threshold AS (
  -- Data-driven p95 threshold on daily max battery temperature.
  SELECT APPROX_QUANTILES(max_batt_temp, 100)[OFFSET(95)] AS p95_max_temp
  FROM daily
)
SELECT
  d.vehicle_id,
  d.event_date,
  d.avg_soc,
  d.min_soc,
  d.avg_batt_temp,
  d.max_batt_temp,
  d.avg_voltage,
  d.voltage_stddev,
  d.avg_motor_temp,
  d.avg_speed,
  d.avg_power,
  d.daily_energy_kwh,
  d.charging_intervals,
  h.health_score,
  h.total_energy_kwh  AS lifetime_energy_kwh,
  h.charging_hours    AS lifetime_charging_hours,
  (d.max_batt_temp > t.p95_max_temp) AS is_anomaly
FROM daily d
CROSS JOIN threshold t
LEFT JOIN `project-623b2045-f641-41e7-894.ev_analytics.battery_health_spark` h
  USING (vehicle_id);


-- -----------------------------------------------------------------------------
-- Phase 6 Step 2: Train BigQuery ML logistic regression model
-- Model type: LOGISTIC_REG (binary classification)
-- auto_class_weights=TRUE handles the 95/5 class imbalance — without this,
-- the model learns to predict FALSE for everything and gets 95% accuracy.
-- data_split_method=AUTO_SPLIT: BigQuery automatically splits 80/20 train/eval.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE MODEL `project-623b2045-f641-41e7-894.ev_analytics.battery_anomaly_model`
OPTIONS (
  model_type         = 'LOGISTIC_REG',
  input_label_cols   = ['is_anomaly'],
  auto_class_weights = TRUE,
  data_split_method  = 'AUTO_SPLIT',
  max_iterations     = 50
) AS
SELECT
  avg_soc, min_soc, avg_batt_temp, max_batt_temp, avg_voltage,
  voltage_stddev, avg_motor_temp, avg_speed, avg_power,
  daily_energy_kwh, charging_intervals, health_score,
  lifetime_energy_kwh, lifetime_charging_hours,
  is_anomaly
FROM `project-623b2045-f641-41e7-894.ev_analytics.ml_features`;


-- -----------------------------------------------------------------------------
-- Phase 6 Step 3: Evaluate the model
-- Key metrics to understand:
--   precision: of all predicted anomalies, how many were real? (low = many false alarms)
--   recall:    of all real anomalies, how many did we catch? (high = few missed)
--   roc_auc:   overall discrimination ability (0.84 = good for this dataset size)
-- With AUTO_CLASS_WEIGHTS + imbalanced data, recall is prioritised over precision
-- (catches more true anomalies at the cost of more false alarms). For a safety
-- use case (battery failures) high recall is usually the right tradeoff.
-- -----------------------------------------------------------------------------
SELECT *
FROM ML.EVALUATE(MODEL `project-623b2045-f641-41e7-894.ev_analytics.battery_anomaly_model`,
  (SELECT avg_soc, min_soc, avg_batt_temp, max_batt_temp, avg_voltage,
          voltage_stddev, avg_motor_temp, avg_speed, avg_power,
          daily_energy_kwh, charging_intervals, health_score,
          lifetime_energy_kwh, lifetime_charging_hours, is_anomaly
   FROM `project-623b2045-f641-41e7-894.ev_analytics.ml_features`));


-- -----------------------------------------------------------------------------
-- Phase 6 Step 4: Run ML.PREDICT and rank vehicles by anomaly probability
-- UNNEST(predicted_is_anomaly_probs) expands the probability array so we can
-- filter to just the TRUE-class probability for ranking.
-- -----------------------------------------------------------------------------
SELECT
  p.vehicle_id,
  p.event_date,
  p.predicted_is_anomaly,
  ROUND(prob.prob, 4) AS anomaly_probability,
  f.max_batt_temp,
  f.avg_batt_temp,
  f.health_score
FROM ML.PREDICT(MODEL `project-623b2045-f641-41e7-894.ev_analytics.battery_anomaly_model`,
  (SELECT vehicle_id, event_date,
          avg_soc, min_soc, avg_batt_temp, max_batt_temp, avg_voltage,
          voltage_stddev, avg_motor_temp, avg_speed, avg_power,
          daily_energy_kwh, charging_intervals, health_score,
          lifetime_energy_kwh, lifetime_charging_hours
   FROM `project-623b2045-f641-41e7-894.ev_analytics.ml_features`)) p,
UNNEST(predicted_is_anomaly_probs) AS prob
JOIN `project-623b2045-f641-41e7-894.ev_analytics.ml_features` f
  ON p.vehicle_id = f.vehicle_id AND p.event_date = f.event_date
WHERE prob.label = TRUE
ORDER BY anomaly_probability DESC
LIMIT 20;
