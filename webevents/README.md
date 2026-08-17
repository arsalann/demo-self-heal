# webevents — website traffic analytics

Marketing's view of the Harborside storefront: pageview events conformed into a
clean event stream, a daily traffic breakdown, and a traffic-to-order conversion
table that reaches into the shop pipeline.

**Consumers:** the marketing analytics dashboard and Growth ad-hoc analysis.
**Owner:** Priya (growth), `priya@harborside.example`. Cost center `MKT-330`.

## Why this pipeline looks like this

- **The source is 4-6 hours late, and that is designed for, not a bug.** The
  analytics vendor delivers events hours after they happen, so `webevents_raw.pageviews`
  carries an `interval_modifiers: { start: -6h }` shift. Without it, every run
  would report the last few hours as missing and page someone about a gap that
  isn't real. This is exactly the kind of intent that has to be written down so an
  agent doesn't "fix" a working pipeline.
- **Dedup lives in stage.** Replayed ingestions can repeat events, so
  `webevents_stage.pageviews_clean` resolves them once by `inserted_at`.
- **Conversion runs on schedule regardless of shop.** `traffic_conversion_daily`
  reads shop orders, but as a *symbolic* dependency: marketing monitoring must
  not stall because a finance pipeline is late.

## Layers and lineage

```
webevents_raw.pageviews ─► webevents_stage.pageviews_clean ─┬─► webevents_report.daily_pageviews
                                                            └─► webevents_report.traffic_conversion_daily
shop_stage.orders_clean ──(external URI, symbolic / non-blocking)──► webevents_report.traffic_conversion_daily
```

| Asset | Layer | What one row is |
|---|---|---|
| `webevents_raw.pageviews` | raw | one pageview event (source-faithful, append) |
| `webevents_stage.pageviews_clean` | stage | one deduplicated pageview event |
| `webevents_report.daily_pageviews` | report | one (date, country, browser) traffic slice |
| `webevents_report.traffic_conversion_daily` | report | one day: sessions, orders, conversion rate |

### Dependency kinds shown here

- **Regular (by name):** stage → raw, report → stage.
- **External URI, symbolic (non-blocking):** `traffic_conversion_daily` depends on
  `bigquery://harborside-analytics.shop_stage.orders_clean` with `mode: symbolic`.
  The edge shows in lineage but does not gate the run.

## Governance features shown here

- **Interval modifiers** on the raw asset, to model a late source.
- **Column checks:** `not_null`, `unique`, `non_negative`, `positive`, `pattern`
  (country code), `accepted_values` (device class), `min`.
- **Custom SQL check:** `known_browsers_only` categorical-contract guard.
- A **unit test** on `traffic_conversion_daily` that mocks both the marketing and
  the shop inputs — a unit test across a pipeline boundary.

## Designed incidents (the self-heal surface)

| Incident | When | Signal | Expected classification |
|---|---|---|---|
| Indonesia traffic spike | 2026-05-18 | pageviews jump ~3x, ID drives it | anomaly, single-dimension driver |
| New browser (Arc) | from 2026-05-16 | `known_browsers_only` warns | schema drift, enum value added |
| Multi-day source gap | 2026-05-23..25 | no new event rows | stale / source-down |

## Useful commands

```bash
bruin validate ./webevents
bruin lineage ./webevents/assets/report/traffic_conversion_daily.sql --full
bruin run ./webevents --start-date 2026-03-01 --end-date 2026-05-15
bruin unit-test ./webevents/assets/report/traffic_conversion_daily.sql
```
