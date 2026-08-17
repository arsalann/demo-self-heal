"""@bruin
name: iot_raw.sensor_readings
type: python
image: python:3.11
connection: gcp-default
description: |
  Raw environmental readings from the sensor gateways in Harborside's
  fulfillment centers. One row per (sensor, hour): temperature, humidity, and
  battery level, with the time the sensor took the reading and the time the row
  landed in the warehouse.

  This asset emulates the upstream sensor-gateway source with a deterministic
  generator so the demo is reproducible offline. Twelve sensors emit one reading
  per hour; the same run interval always produces the same rows. It also seeds a
  few designed incidents so the repo doubles as a self-heal exercise (the stage
  and report layers are the surface an agent fixes, not this generator):

    1. Impossible values (quality) — on 2026-05-16 sensor S07 reports
       temperature_c = 999.0 every hour. `iot_stage` quarantines it; the
       physical-range custom check on the clean table stays green.
    2. Observed type drift (schema) — before 2026-05-18 temperature_c carries
       decimals (22.473); from 2026-05-18 the source rounds to whole numbers
       (22.0). The declared type is still DOUBLE, so this is a value-shape
       drift, not a hard type failure — escalate rather than auto-fix.
    3. Late-arriving data (freshness) — readings for 2026-05-22 land with a
       created_at one full day after reading_time. The interval-scoped
       `readings_arrive_within_one_hour` check catches it.

materialization:
  type: table
  strategy: append
  incremental_key: reading_time
  partition_by: reading_time
  cluster_by:
    - sensor_id

owner: sam@harborside.example
tags:
  - harborside
  - iot
  - raw
  - sensors
domains:
  - operations
meta:
  layer: raw
  tier: bronze
  team: ops
  cost_center: OPS-101
  source: fulfillment-center sensor gateway
  contains_incidents: "impossible-values;type-drift;late-arriving"

columns:
  - name: sensor_id
    type: VARCHAR
    description: Sensor hardware identifier, for example `S07`. Joins to `iot_raw.sensor_registry`.
    primary_key: true
    nullable: false
    checks:
      - name: not_null
  - name: reading_time
    type: TIMESTAMP
    description: UTC time the sensor took the reading. Grain is one reading per sensor-hour.
    primary_key: true
    nullable: false
    checks:
      - name: not_null
  - name: temperature_c
    type: DOUBLE
    description: >
      Temperature in degrees Celsius as reported by the sensor. Source-faithful:
      physically impossible values are kept here and dropped downstream in
      `iot_stage.valid_sensor_readings`.
    nullable: false
  - name: humidity_pct
    type: DOUBLE
    description: Relative humidity as a percentage, 0-100.
    nullable: false
    checks:
      - name: min
        value: 0
      - name: max
        value: 100
  - name: battery_pct
    type: DOUBLE
    description: Battery level as a percentage, 0-100.
    nullable: false
    checks:
      - name: min
        value: 0
      - name: max
        value: 100
  - name: created_at
    type: TIMESTAMP
    description: UTC time the reading was written to the raw table. Used to detect late arrivals.
    nullable: false
    checks:
      - name: not_null

custom_checks:
  - name: readings_arrive_within_one_hour
    description: >
      created_at should be within one hour of reading_time for the current run
      interval. A larger gap means the reading arrived late. The failure on
      2026-05-22 is the designed late-arriving incident.
    query: |
      SELECT COUNT(*)
      FROM {{ this }}
      WHERE reading_time >= TIMESTAMP('{{ start_timestamp }}')
        AND reading_time <= TIMESTAMP('{{ end_timestamp }}')
        AND created_at > TIMESTAMP_ADD(reading_time, INTERVAL 1 HOUR)
    value: 0
    blocking: false

@bruin"""

import hashlib
import os
import random
from datetime import date, datetime, timedelta

import pandas as pd

SENSOR_IDS = [f"S{i:02d}" for i in range(1, 13)]
TYPE_NARROW_DATE = date(2026, 5, 18)
IMPOSSIBLE_DATE = date(2026, 5, 16)
LATE_DATE = date(2026, 5, 22)


def seed_for(d: date, hour: int) -> int:
    return int(hashlib.sha256(f"{d.isoformat()}T{hour:02d}".encode()).hexdigest()[:8], 16)


def generate_day(d: date) -> pd.DataFrame:
    type_narrow = d >= TYPE_NARROW_DATE
    is_impossible = d == IMPOSSIBLE_DATE
    is_late = d == LATE_DATE

    rows = []
    for hour in range(24):
        rng = random.Random(seed_for(d, hour))
        reading_time = datetime.combine(d, datetime.min.time()) + timedelta(hours=hour)

        if is_late:
            created_at = reading_time + timedelta(days=1)
        else:
            created_at = reading_time + timedelta(minutes=rng.randint(0, 10))

        for sensor_id in SENSOR_IDS:
            if is_impossible and sensor_id == "S07":
                temp = 999.0
            else:
                base = 18.0 + 8.0 * rng.random()
                temp = round(base) if type_narrow else round(base, 3)

            rows.append({
                "sensor_id": sensor_id,
                "reading_time": reading_time,
                "temperature_c": float(temp),
                "humidity_pct": round(30 + 50 * rng.random(), 1),
                "battery_pct": round(40 + 60 * rng.random(), 1),
                "created_at": created_at,
            })

    return pd.DataFrame(rows)


def materialize():
    start_str = os.environ.get("BRUIN_START_DATE", "2026-01-01")
    end_str = os.environ.get("BRUIN_END_DATE", date.today().isoformat())

    start = date.fromisoformat(start_str[:10])
    end = date.fromisoformat(end_str[:10])

    frames = []
    current = start
    while current <= end:
        frames.append(generate_day(current))
        current += timedelta(days=1)

    df = pd.concat(frames, ignore_index=True)
    for column in ("reading_time", "created_at"):
        df[column] = pd.to_datetime(df[column]).astype("datetime64[us]")
    print(f"[iot] generated {len(df):,} readings across {df['reading_time'].dt.date.nunique()} days")
    return df
