"""Phase 5 - PySpark battery health job.

Reads all raw telemetry Parquet from GCS, computes per-vehicle battery health
aggregations, and writes results to BigQuery.

Honest tradeoff documented here (exam-relevant):
    At 201,600 rows this job does NOT need Spark - BigQuery SQL handles it
    trivially and for less cost. We use Spark here to learn the GCS -> Spark
    -> BigQuery pipeline pattern, which justifies itself at billions of rows or
    when the transformation logic is too complex for SQL (e.g. custom ML models,
    complex iterative algorithms, existing Spark codebases).

Run via:
    gcloud dataproc jobs submit pyspark gs://<BUCKET>/spark/battery_health.py \
      --cluster=ev-spark \
      --region=asia-south1 \
      --jars=gs://spark-lib/bigquery/spark-bigquery-with-dependencies_2.12-0.34.0.jar \
      -- \
      --project=<PROJECT> \
      --bucket=<BUCKET>
"""

import argparse
import sys

from pyspark.sql import SparkSession
from pyspark.sql import functions as F


def parse_args(argv):
    parser = argparse.ArgumentParser(description="EV battery health PySpark job")
    parser.add_argument("--project", required=True, help="GCP project id")
    parser.add_argument("--bucket", required=True, help="GCS bucket name (no gs://)")
    parser.add_argument(
        "--input",
        default="raw/telemetry",
        help="GCS path prefix for telemetry Parquet (default: raw/telemetry)",
    )
    parser.add_argument(
        "--output-dataset",
        default="ev_analytics",
        help="BigQuery output dataset (default: ev_analytics)",
    )
    parser.add_argument(
        "--output-table",
        default="battery_health_spark",
        help="BigQuery output table (default: battery_health_spark)",
    )
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv or sys.argv[1:])

    spark = (
        SparkSession.builder
        .appName("ev-battery-health")
        # Tell the BigQuery connector where to stage temporary data.
        .config("temporaryGcsBucket", args.bucket)
        .getOrCreate()
    )
    spark.sparkContext.setLogLevel("WARN")

    input_path = f"gs://{args.bucket}/{args.input}/**/*.parquet"
    print(f"Reading Parquet from: {input_path}")

    # Read all date partitions. Spark reads them in parallel across partitions.
    df = spark.read.parquet(input_path)

    print(f"Total records loaded: {df.count()}")

    # Per-vehicle battery health aggregations.
    # These are the same metrics the plan's Phase 5 specified:
    #   avg/max battery temperature, avg SOC, avg power consumption,
    #   total energy consumed (kWh), time spent charging (hours).
    #
    # Energy per 5-min interval: power_kW * (300/3600) h.
    # Charging time: count of charging_status=True intervals * 5 min / 60.
    health = (
        df
        .groupBy("vehicle_id")
        .agg(
            F.round(F.avg("battery_soc"), 2).alias("avg_soc_pct"),
            F.round(F.avg("battery_temperature"), 2).alias("avg_batt_temp_c"),
            F.round(F.max("battery_temperature"), 2).alias("max_batt_temp_c"),
            F.round(F.avg("battery_voltage"), 2).alias("avg_voltage"),
            F.round(F.avg("motor_temperature"), 2).alias("avg_motor_temp_c"),
            F.round(F.avg("speed"), 2).alias("avg_speed_kmh"),
            F.round(F.avg("power_consumption"), 3).alias("avg_power_kw"),
            # Total energy consumed while driving (positive power draw only).
            F.round(
                F.sum(F.when(F.col("power_consumption") > 0,
                             F.col("power_consumption") * (300 / 3600)).otherwise(0)),
                2,
            ).alias("total_energy_kwh"),
            # Total energy recharged (negative power = energy into pack).
            F.round(
                F.sum(F.when(F.col("power_consumption") < 0,
                             -F.col("power_consumption") * (300 / 3600)).otherwise(0)),
                2,
            ).alias("total_charged_kwh"),
            # Hours spent charging.
            F.round(
                F.sum(F.when(F.col("charging_status") == True, 1).otherwise(0))
                * 5 / 60,
                2,
            ).alias("charging_hours"),
            F.count("*").alias("total_readings"),
        )
        .orderBy("vehicle_id")
    )

    # Add a simple battery health score: 100 - penalty for high avg temp.
    # This is deliberately simple — a real health score would use degradation
    # curves, cycle counts, and voltage variance. Marking it as synthetic.
    health = health.withColumn(
        "health_score",
        F.round(
            F.greatest(
                F.lit(0.0),
                F.lit(100.0) - (F.col("avg_batt_temp_c") - 25.0) * 2.0,
            ),
            1,
        ),
    )

    output_table = f"{args.project}:{args.output_dataset}.{args.output_table}"
    print(f"Writing {health.count()} rows to BigQuery: {output_table}")

    (
        health.write
        .format("bigquery")
        .option("table", output_table)
        .option("writeMethod", "direct")
        .mode("overwrite")
        .save()
    )

    print("Job complete.")
    spark.stop()


if __name__ == "__main__":
    main()
