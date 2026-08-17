/* @bruin
name: iot_report.sensor_health_daily
type: bq.sql
connection: gcp-default
description: >
  Daily health scorecard for every sensor. One row per (sensor, day) with
  temperature, humidity and battery summaries, how many of the expected 24
  hourly readings actually arrived (uptime), and the fulfillment center and zone
  the sensor sits in. This is the table the ops dashboard reads. The zone comes
  from the sensor registry, which is joined as a symbolic dependency because it
  is slowly-changing reference data that must not gate the daily run.

depends:
  - iot_stage.valid_sensor_readings
  - asset: iot_raw.sensor_registry
    mode: symbolic

materialization:
  type: table
  strategy: create+replace
  partition_by: reading_date
  cluster_by:
    - fulfillment_center
    - sensor_id

owner: sam@harborside.example
tags:
  - harborside
  - iot
  - report
  - sensors
domains:
  - operations
meta:
  layer: report
  tier: gold
  team: ops
  cost_center: OPS-101
  sla: "07:00 UTC"
  consumers: ops-monitoring-dashboard

columns:
  - name: sensor_id
    type: VARCHAR
    description: Sensor hardware identifier. Grain is one row per sensor per day.
    primary_key: true
    nullable: false
    checks:
      - name: not_null
  - name: reading_date
    type: DATE
    description: UTC calendar date of the readings.
    primary_key: true
    nullable: false
    checks:
      - name: not_null
  - name: fulfillment_center
    type: VARCHAR
    description: Fulfillment center the sensor is installed in, from the registry.
  - name: zone
    type: VARCHAR
    description: Storage zone the sensor monitors, from the registry.
  - name: reading_count
    type: INTEGER
    description: Number of cleaned readings received for the sensor that day.
    checks:
      - name: positive
  - name: expected_reading_count
    type: INTEGER
    description: Readings expected per sensor per day (one per hour, so 24).
  - name: uptime_pct
    type: DOUBLE
    description: reading_count divided by expected_reading_count, as a percentage 0-100.
    checks:
      - name: min
        value: 0
      - name: max
        value: 100
  - name: avg_temperature_c
    type: DOUBLE
    description: Mean temperature in degrees Celsius for the sensor-day.
  - name: min_temperature_c
    type: DOUBLE
    description: Minimum temperature in degrees Celsius for the sensor-day.
  - name: max_temperature_c
    type: DOUBLE
    description: Maximum temperature in degrees Celsius for the sensor-day.
  - name: avg_humidity_pct
    type: DOUBLE
    description: Mean relative humidity for the sensor-day, 0-100.
  - name: avg_battery_pct
    type: DOUBLE
    description: Mean battery level for the sensor-day, 0-100.
    checks:
      - name: non_negative
  - name: min_battery_pct
    type: DOUBLE
    description: Lowest battery reading for the sensor-day; an early warning for battery replacement.

custom_checks:
  - name: cold_storage_stays_cold
    description: >
      Cold-storage zones must average below 10 degrees Celsius. A warmer daily
      average points to a failing unit and is an ops incident, not a data bug.
    query: |
      SELECT COUNT(*)
      FROM {{ this }}
      WHERE zone = 'cold-storage'
        AND avg_temperature_c > 10
    value: 0
    blocking: false

unit_tests:
  - name: rolls_up_readings_and_uptime_per_sensor_day
    description: >
      Two readings for one cold-storage sensor on one day should roll up to a
      single row with the correct averages, min/max, and an uptime of 2/24.
    inputs:
      - asset: iot_stage.valid_sensor_readings
        rows:
          - {sensor_id: S03, reading_time: "2026-05-01 00:00:00", temperature_c: 4.0, humidity_pct: 55.0, battery_pct: 90.0, created_at: "2026-05-01 00:05:00"}
          - {sensor_id: S03, reading_time: "2026-05-01 01:00:00", temperature_c: 6.0, humidity_pct: 57.0, battery_pct: 88.0, created_at: "2026-05-01 01:05:00"}
      - asset: iot_raw.sensor_registry
        rows:
          - {sensor_id: S03, fulfillment_center: FC-EAST, zone: cold-storage, model: HarborTherm-2C, install_date: "2025-11-04"}
    expected:
      match: exact
      rows:
        - {sensor_id: S03, reading_date: "2026-05-01", fulfillment_center: FC-EAST, zone: cold-storage, reading_count: 2, expected_reading_count: 24, uptime_pct: 8.33, avg_temperature_c: 5.0, min_temperature_c: 4.0, max_temperature_c: 6.0, avg_humidity_pct: 56.0, avg_battery_pct: 89.0, min_battery_pct: 88.0}

@bruin */

WITH daily AS (
    SELECT
        sensor_id,
        DATE(reading_time) AS reading_date,
        COUNT(*) AS reading_count,
        ROUND(AVG(temperature_c), 4) AS avg_temperature_c,
        MIN(temperature_c) AS min_temperature_c,
        MAX(temperature_c) AS max_temperature_c,
        ROUND(AVG(humidity_pct), 4) AS avg_humidity_pct,
        ROUND(AVG(battery_pct), 4) AS avg_battery_pct,
        MIN(battery_pct) AS min_battery_pct
    FROM iot_stage.valid_sensor_readings
    GROUP BY 1, 2
)

SELECT
    daily.sensor_id,
    daily.reading_date,
    registry.fulfillment_center,
    registry.zone,
    daily.reading_count,
    24 AS expected_reading_count,
    ROUND(daily.reading_count / 24 * 100, 2) AS uptime_pct,
    daily.avg_temperature_c,
    daily.min_temperature_c,
    daily.max_temperature_c,
    daily.avg_humidity_pct,
    daily.avg_battery_pct,
    daily.min_battery_pct
FROM daily
LEFT JOIN iot_raw.sensor_registry AS registry
    ON daily.sensor_id = registry.sensor_id
ORDER BY daily.reading_date DESC, daily.sensor_id
