/* @bruin
name: iot_report.hourly_sensor_stats
type: bq.sql
connection: gcp-default
description: >
  One row per (sensor, hour) with the cleaned reading and the ingest lag between
  when the reading was taken and when it landed. Built from cleaned readings, so
  impossible values are already removed. This is the operational surface the ops
  team watches for late data; the interval-scoped lag check is the tripwire for
  the late-arriving incident.

depends:
  - iot_stage.valid_sensor_readings

materialization:
  type: table
  strategy: create+replace
  partition_by: hour
  cluster_by:
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
  sla: "hourly, within 60 min of reading"

columns:
  - name: sensor_id
    type: VARCHAR
    description: Sensor hardware identifier.
    primary_key: true
    nullable: false
    checks:
      - name: not_null
  - name: hour
    type: TIMESTAMP
    description: The reading hour (equals reading_time at hourly grain).
    primary_key: true
    nullable: false
    checks:
      - name: not_null
  - name: temperature_c
    type: DOUBLE
    description: Temperature in degrees Celsius for the sensor-hour.
    nullable: false
  - name: humidity_pct
    type: DOUBLE
    description: Relative humidity as a percentage, 0-100.
    nullable: false
  - name: battery_pct
    type: DOUBLE
    description: Battery level as a percentage, 0-100.
    nullable: false
  - name: ingest_lag_minutes
    type: DOUBLE
    description: Minutes between reading_time and created_at. Above 60 means the reading arrived late.
    nullable: false
    checks:
      - name: non_negative

custom_checks:
  - name: ingest_lag_under_60_min
    description: >
      Every reading in the current run interval should land within 60 minutes.
      The failure on 2026-05-22 is the designed late-arriving incident.
    query: |
      SELECT COUNT(*)
      FROM {{ this }}
      WHERE hour >= TIMESTAMP('{{ start_timestamp }}')
        AND hour <= TIMESTAMP('{{ end_timestamp }}')
        AND ingest_lag_minutes > 60
    value: 0
    blocking: false

@bruin */

SELECT
    sensor_id,
    reading_time AS hour,
    temperature_c,
    humidity_pct,
    battery_pct,
    TIMESTAMP_DIFF(created_at, reading_time, SECOND) / 60.0 AS ingest_lag_minutes
FROM iot_stage.valid_sensor_readings
ORDER BY hour DESC, sensor_id
