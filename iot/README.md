# iot — fulfillment-center environmental monitoring

Harborside stores physical goods in three fulfillment centers (FC-EAST, FC-WEST,
FC-CENTRAL). Twelve sensors report temperature, humidity, and battery once an
hour so the ops team can catch a failing cold-storage unit before product spoils.
This pipeline turns those raw readings into a clean, deduplicated series and a
daily per-sensor health scorecard.

**Consumers:** the ops on-call dashboard reads `iot_report.sensor_health_daily`.
**Owner:** Sam (ops), `sam@harborside.example`. Cost center `OPS-101`.

## Why this pipeline looks like this

- It is **operational monitoring, not historical reporting**. Each layer keeps a
  full series but the value is in the last day or two, so `catchup: false` — a
  missed day is not backfilled by default because a two-day-old temperature alert
  is worthless.
- The raw table is **source-faithful and append-only**. Impossible values are
  kept in raw and removed downstream, so the raw table always matches what the
  sensor gateway actually sent. Cleaning happens once, in `iot_stage`.
- Rejected rows are **quarantined, not deleted** (`iot_stage.sensor_readings_quarantine`),
  so a bad sensor is auditable rather than silently dropped.

## Layers and lineage

```
iot_raw.sensor_readings ─┬─► iot_stage.valid_sensor_readings ─┬─► iot_report.hourly_sensor_stats
                         │                                    └─► iot_report.sensor_health_daily
                         └─► iot_stage.sensor_readings_quarantine
iot_raw.sensor_registry ····(symbolic)····························► iot_report.sensor_health_daily
```

| Asset | Layer | What one row is |
|---|---|---|
| `iot_raw.sensor_readings` | raw | one reading per sensor-hour (source-faithful, append) |
| `iot_raw.sensor_registry` | raw | one sensor: its center, zone, model, install date (CSV **seed**) |
| `iot_stage.valid_sensor_readings` | stage | one cleaned reading per sensor-hour |
| `iot_stage.sensor_readings_quarantine` | stage | one rejected reading, with the reason |
| `iot_report.hourly_sensor_stats` | report | one sensor-hour with ingest lag |
| `iot_report.sensor_health_daily` | report | one sensor-day: uptime, temp/humidity/battery summary |

### Dependency kinds shown here

- **Regular (by name):** stage → raw, report → stage.
- **Symbolic:** `sensor_health_daily` reads `iot_raw.sensor_registry` but declares
  it `mode: symbolic`, because the registry is slowly-changing reference data and
  a daily run should not wait on it.

## Governance features shown here

- A CSV **seed** asset (`sensor_registry`).
- **Column checks:** `not_null`, `unique`, `min`/`max`, `positive`, `non_negative`,
  `accepted_values`, and a `relationships` foreign-key check (`valid_sensor_readings.sensor_id`
  → `sensor_registry.sensor_id`).
- **Custom SQL checks:** interval-scoped freshness (`readings_arrive_within_one_hour`,
  `ingest_lag_under_60_min`), a blocking physical-range check, and a cross-column
  business rule (`cold_storage_stays_cold`).
- A **unit test** on `sensor_health_daily` for the daily roll-up and uptime math.
- **Partitioning/clustering** on every warehouse asset.

## Designed incidents (the self-heal surface)

The raw generator emulates the sensor source and seeds three incidents. The thing
an agent fixes is the stage/report SQL or a check — not the generator.

| Incident | When | Signal | Expected classification |
|---|---|---|---|
| Impossible values | 2026-05-16 | S07 reports 999°C; rows land in `sensor_readings_quarantine`, clean check stays green | source bug, contained by quarantine |
| Observed type drift | from 2026-05-18 | `temperature_c` stops carrying decimals; column is still `DOUBLE` | value-shape drift → escalate, don't auto-fix |
| Late-arriving data | 2026-05-22 | interval-scoped `readings_arrive_within_one_hour` / `ingest_lag_under_60_min` fail | late-arriving / freshness |

## Useful commands

```bash
bruin validate ./iot
bruin lineage ./iot/assets/report/sensor_health_daily.sql --full
# seed clean history, then exercise one incident at a time with narrow windows:
bruin run ./iot --start-date 2026-03-01 --end-date 2026-05-15
bruin run ./iot/assets/raw/sensor_readings.py --start-date 2026-05-16 --end-date 2026-05-17
bruin run --only checks ./iot/assets/report/hourly_sensor_stats.sql
```
