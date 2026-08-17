# shop — one-time storefront revenue

The storefront side of Harborside's revenue: one-time orders (as opposed to the
Home Box subscription, which lives in the `stripe` pipeline). This pipeline
conforms raw orders and products, then publishes the daily revenue tables Finance
and the exec dashboard read.

**Consumers:** the exec revenue dashboard and Finance ad-hoc analysis.
**Owner:** Dana (finance), `dana@harborside.example`. Cost center `FIN-204`.

## Why this pipeline looks like this

- **Dedup lives in the stage layer, once.** Raw orders are append-only and can
  carry repeated `order_id`s (retries, connector replays). `shop_stage.orders_clean`
  is the single place that resolves them, so every report is duplicate-free
  without each one re-implementing the rule.
- **The product-category rename is absorbed in stage.** The source sometimes calls
  the column `category` and sometimes `product_category`; `shop_stage.products_clean`
  normalizes both to `category` so reports never see the drift.
- **The anomaly threshold is a variable, not a constant.** `orders_daily` guards
  against daily revenue spiking past `anomaly_multiplier`× the 28-day median.
  The multiplier is a pipeline variable (`{{ var.anomaly_multiplier }}`, default 2)
  so Finance can tune sensitivity without a code change.

## Layers and lineage

```
shop_raw.orders   ─► shop_stage.orders_clean   ─┬─► shop_report.orders_daily
                                                ├─► shop_report.revenue_daily
                                                └─► shop_report.subscriber_revenue_daily
shop_raw.products ─► shop_stage.products_clean  ─► shop_report.revenue_daily

stripe_stage.subscriptions ──(external URI, blocking)──► shop_report.subscriber_revenue_daily
```

| Asset | Layer | What one row is |
|---|---|---|
| `shop_raw.orders` | raw | one raw order line (source-faithful, append) |
| `shop_raw.products` | raw | one product snapshot per run |
| `shop_stage.orders_clean` | stage | one deduplicated order (exposed by `uri:`) |
| `shop_stage.products_clean` | stage | one product, latest version, category normalized |
| `shop_report.orders_daily` | report | one day: order/user/country counts + revenue |
| `shop_report.revenue_daily` | report | one (day, country, category) revenue slice |
| `shop_report.subscriber_revenue_daily` | report | one day: one-time revenue + active-subscription count |
| `shop_report.orders_enriched` | report | one enriched order — the **reference asset** (below) |

### Reference asset: everything on one asset

`shop_report.orders_enriched` is a deliberately complete example — a single asset
that exercises every asset-level Bruin feature in one file, for walkthroughs. It
carries `owner`/`tags`/`domains`/`meta`, a published `uri`, `interval_modifiers`,
all three dependency kinds (regular, symbolic, external URI), a `time_interval`
materialization with `partition_by`/`cluster_by`, columns using `extends` (glossary),
`foreign_key`, `primary_key`/`nullable`, column checks, a custom SQL check, and a
`unit_test`. Materialization strategies are mutually exclusive, so it uses
`time_interval` and notes the `merge`/`update_on_merge` alternative inline.

### Dependency kinds shown here

- **Regular (by name):** stage → raw, report → stage.
- **External URI (blocking data contract):** `subscriber_revenue_daily` depends on
  `bigquery://harborside-analytics.stripe_stage.subscriptions`. It waits for the
  stripe pipeline to cover the interval. `shop_stage.orders_clean` in turn
  publishes its own `uri:` for the marketing pipeline to consume.

## Governance features shown here

- **Pipeline variables** with JSON-schema validation (`anomaly_multiplier`).
- **Column checks:** `not_null`, `unique`, `positive`, `non_negative`, `pattern`
  (country code), `accepted_values` (category).
- **Custom SQL checks:** a duplicate-key warning on raw, a rolling-median revenue
  anomaly guardrail, a zero-revenue-day tripwire, and a cross-pipeline
  contract-health check.
- A **unit test** on `revenue_daily` covering the order↔category join and revenue sum.

## Designed incidents (the self-heal surface)

| Incident | When | Signal | Expected classification |
|---|---|---|---|
| Duplicate order IDs | from 2026-05-16 | `no_duplicate_order_ids_in_source` warns; stage dedups | quality, contained by dedup |
| Country revenue spike | 2026-05-20 | `daily_revenue_within_median_multiple` fails; TR drives it | anomaly, single-dimension driver |
| Product category rename | from 2026-05-18 | source sends `product_category`; stage normalizes | schema drift, column renamed |
| Source stall | 2026-05-24..25 | no new order rows; zero-revenue / freshness signals | stale / source-down |
| Missed stripe interval | any | `subscriber_revenue_daily` waits on the stripe contract | cross-pipeline missed interval |

## Useful commands

```bash
bruin validate ./shop
bruin lineage ./shop/assets/report/subscriber_revenue_daily.sql --full
bruin run ./shop --start-date 2026-03-01 --end-date 2026-05-15
bruin run ./shop/assets/report/orders_daily.sql --var anomaly_multiplier=3
bruin unit-test ./shop/assets/report/revenue_daily.sql
```
