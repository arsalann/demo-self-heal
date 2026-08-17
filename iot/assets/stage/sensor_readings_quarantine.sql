/* @bruin
name: iot_stage.sensor_readings_quarantine
type: bq.sql
connection: gcp-default
description: >
  Sensor readings deliberately dropped from `iot_stage.valid_sensor_readings`,
  kept for auditability with the reason they were rejected. Deduplicated the same
  way as the clean table, then filtered to the impossible-temperature rows. One
  row per rejected sensor-hour. A steady stream of rows here is the earliest
  signal of a misbehaving sensor or a source-side bug.

depends:
  - iot_raw.sensor_readings

materialization:
  type: table
  strategy: create+replace

owner: sam@harborside.example
tags:
  - harborside
  - iot
  - stage
  - quarantine
domains:
  - operations
meta:
  layer: stage
  tier: silver
  team: ops
  cost_center: OPS-101
  purpose: audit trail for rejected rows

columns:
  - name: sensor_id
    type: VARCHAR
    description: Sensor hardware identifier of the rejected reading.
    primary_key: true
    nullable: false
  - name: reading_time
    type: TIMESTAMP
    description: UTC time the rejected reading was taken.
    primary_key: true
    nullable: false
  - name: failure_reason
    type: VARCHAR
    description: Why the reading was quarantined.
    primary_key: true
    nullable: false
    checks:
      - name: accepted_values
        value: [temperature_out_of_physical_range]
  - name: temperature_c
    type: DOUBLE
    description: The rejected temperature in degrees Celsius.
    nullable: false
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
    'temperature_out_of_physical_range' AS failure_reason,
    temperature_c,
    humidity_pct,
    battery_pct,
    created_at
FROM deduped
WHERE temperature_c < -50 OR temperature_c > 70
ORDER BY reading_time DESC, sensor_id
