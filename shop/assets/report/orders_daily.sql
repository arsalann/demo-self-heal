/* @bruin
name: shop_report.orders_daily
type: bq.sql
connection: gcp-default
description: >
  Daily storefront totals: one row per order_date with order count, distinct
  users, country coverage, and gross revenue. Built on deduplicated orders, so
  the numbers are already free of repeated source keys. This is the surface the
  daily revenue anomaly guardrail watches — the designed 2026-05-20 spike shows
  up here as a daily total more than `anomaly_multiplier`x the 28-day median.

depends:
  - shop_stage.orders_clean

materialization:
  type: table
  strategy: create+replace
  partition_by: order_date

owner: dana@harborside.example
tags:
  - harborside
  - shop
  - report
  - revenue
domains:
  - commerce
  - finance
meta:
  layer: report
  tier: gold
  team: finance
  cost_center: FIN-204
  sla: "06:00 UTC"
  consumers: exec-revenue-dashboard

columns:
  - name: order_date
    type: DATE
    description: UTC calendar date. Grain is one row per day.
    primary_key: true
    nullable: false
    checks:
      - name: not_null
      - name: unique
  - name: order_count
    type: INTEGER
    description: Number of distinct orders that day.
    checks:
      - name: positive
  - name: distinct_users
    type: INTEGER
    description: Number of distinct customers who ordered that day.
    checks:
      - name: positive
  - name: distinct_countries
    type: INTEGER
    description: Number of distinct countries orders came from that day.
    checks:
      - name: positive
  - name: revenue_usd
    type: DOUBLE
    description: Gross order revenue in USD for the day.
    checks:
      - name: positive

custom_checks:
  - name: daily_revenue_within_median_multiple
    description: >
      A day's revenue should not exceed `anomaly_multiplier` times the median of
      the prior 28 days. A breach is a single-day spike to investigate (usually a
      single-dimension driver such as one country), not necessarily a data bug.
      The multiplier is a pipeline variable so it can be tuned without editing SQL.
    query: |
      WITH daily AS (
        SELECT order_date, revenue_usd
        FROM {{ this }}
      ),
      with_baseline AS (
        SELECT
          daily.order_date,
          daily.revenue_usd,
          APPROX_QUANTILES(baseline.revenue_usd, 2)[OFFSET(1)] AS baseline
        FROM daily
        LEFT JOIN daily AS baseline
          ON baseline.order_date >= DATE_SUB(daily.order_date, INTERVAL 28 DAY)
         AND baseline.order_date < daily.order_date
        GROUP BY daily.order_date, daily.revenue_usd
      )
      SELECT COUNT(*)
      FROM with_baseline
      WHERE baseline IS NOT NULL
        AND revenue_usd > {{ var.anomaly_multiplier }} * baseline
    value: 0
    blocking: false

@bruin */

SELECT
    order_date,
    COUNT(*) AS order_count,
    COUNT(DISTINCT user_id) AS distinct_users,
    COUNT(DISTINCT country) AS distinct_countries,
    ROUND(SUM(amount_usd), 2) AS revenue_usd
FROM shop_stage.orders_clean
GROUP BY 1
ORDER BY 1 DESC
