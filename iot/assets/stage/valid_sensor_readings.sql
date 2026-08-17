/* @bruin
name: iot_stage.valid_sensor_readings
type: bq.sql
connection: gcp-default
description: >
  Cleaned sensor readings for downstream reporting. Deduplicates the append-only
  raw table by (sensor, reading_time) keeping the latest row by created_at, then
  drops physically impossible temperatures so bad source records cannot reach the
  report layer. Rejected rows are preserved in
  `iot_stage.sensor_readings_quarantine`. One row per sensor-hour.

depends:
  - iot_raw.sensor_readings

materialization:
  type: table
  strategy: create+replace
  partition_by: reading_time
  cluster_by:
    - sensor_id

owner: sam@harborside.example
tags:
  - harborside
  - iot
  - stage
  - sensors
domains:
  - operations
meta:
  layer: stage
  tier: silver
  team: ops
  cost_center: OPS-101

columns:
  - name: sensor_id
    type: VARCHAR
    description: Sensor hardware identifier. Every reading must belong to a registered sensor.
    primary_key: true
    nullable: false
    foreign_key:
      table: iot_raw.sensor_registry
      column: sensor_id
    checks:
      - name: not_null
      - name: relationships
  - name: reading_time
    type: TIMESTAMP
    description: UTC time the sensor took the reading. Grain is one row per sensor-hour.
    primary_key: true
    nullable: false
    checks:
      - name: not_null
  - name: temperature_c
    type: DOUBLE
    description: Temperature in degrees Celsius, constrained to the physical range -50..70.
    nullable: false
    checks:
      - name: min
        value: -50
      - name: max
        value: 70
  - name: humidity_pct
    type: DOUBLE
    description: Relative humidity as a percentage, 0-100.
    nullable: false
  - name: battery_pct
    type: DOUBLE
    description: Battery level as a percentage, 0-100.
    nullable: false
  - name: created_at
    type: TIMESTAMP
    description: UTC time the reading was written to the raw table.
    nullable: false

custom_checks:
  - name: temperature_in_physical_range
    description: Cleaned readings must contain only physically plausible temperatures.
    query: |
      SELECT COUNT(*)
      FROM {{ this }}
      WHERE temperature_c < -50 OR temperature_c > 70
    value: 0
    blocking: true

@bruin */

WITH deduped AS (
    SELECT
        sensor_id,
        reading_time,
        temperature_c,
        humidity_pct,
        battery_pct,
        created_at
    FROM iot_raw.sensor_readings
    WHERE sensor_id IS NOT NULL
      AND reading_time IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY sensor_id, reading_time
        ORDER BY created_at DESC, temperature_c DESC, humidity_pct DESC, battery_pct DESC
    ) = 1
)

SELECT
    sensor_id,
    reading_time,
    temperature_c,
    humidity_pct,
    battery_pct,
    created_at
FROM deduped
WHERE temperature_c BETWEEN -50 AND 70
ORDER BY reading_time DESC, sensor_id
