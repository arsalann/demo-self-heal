/* @bruin
name: shop_report.subscriber_revenue_daily
type: bq.sql
connection: gcp-default
description: >
  Daily view of the two revenue streams side by side: one-time storefront
  revenue from this pipeline, and the count of active Home Box subscriptions from
  the stripe pipeline. One row per order_date. This is the only shop asset that
  reaches across a pipeline boundary, and it does so as a blocking data contract:
  it depends on `stripe_stage.subscriptions` by URI, so a run waits for stripe to
  have covered the interval before it builds. If stripe misses an interval and
  runs with `catchup: false`, this asset waits — that is the cross-pipeline
  missed-interval scenario in the self-heal playbook.

depends:
  - shop_stage.orders_clean
  - uri: bigquery://harborside-analytics.stripe_stage.subscriptions

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
  - cross-pipeline
domains:
  - commerce
  - finance
meta:
  layer: report
  tier: gold
  team: finance
  cost_center: FIN-204
  sla: "06:30 UTC"
  cross_pipeline_upstream: stripe
  contract: blocking on stripe_stage.subscriptions

columns:
  - name: order_date
    type: DATE
    description: UTC calendar date. Grain is one row per day.
    primary_key: true
    nullable: false
    checks:
      - name: not_null
      - name: unique
  - name: one_time_order_count
    type: INTEGER
    description: Number of one-time storefront orders that day.
    checks:
      - name: non_negative
  - name: one_time_revenue_usd
    type: DOUBLE
    description: Gross one-time storefront revenue in USD that day.
    checks:
      - name: non_negative
  - name: active_subscription_count
    type: INTEGER
    description: >
      Home Box subscriptions that were active or past-due as of that date, from
      the stripe pipeline. Point-in-time based on start and cancellation dates.
    checks:
      - name: non_negative

custom_checks:
  - name: subscription_count_is_populated
    description: >
      Every day should carry a subscription count sourced from stripe. A run of
      zeros across recent days means the cross-pipeline contract did not resolve
      and the stripe upstream should be checked before trusting this table.
    query: |
      SELECT COUNT(*)
      FROM (
        SELECT order_date
        FROM {{ this }}
        WHERE order_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
        GROUP BY order_date
        HAVING MAX(active_subscription_count) = 0
      )
    value: 0
    blocking: false

@bruin */

WITH one_time AS (
    SELECT
        order_date,
        COUNT(*) AS one_time_order_count,
        ROUND(SUM(amount_usd), 2) AS one_time_revenue_usd
    FROM shop_stage.orders_clean
    GROUP BY 1
),

active_subs AS (
    SELECT
        one_time.order_date,
        COUNT(DISTINCT subs.stripe_subscription_id) AS active_subscription_count
    FROM one_time
    LEFT JOIN stripe_stage.subscriptions AS subs
        ON DATE(subs.subscription_started_at) <= one_time.order_date
       AND subs.subscription_status IN ('active', 'past_due')
       AND (subs.canceled_at IS NULL OR DATE(subs.canceled_at) > one_time.order_date)
    GROUP BY 1
)

SELECT
    one_time.order_date,
    one_time.one_time_order_count,
    one_time.one_time_revenue_usd,
    active_subs.active_subscription_count
FROM one_time
JOIN active_subs USING (order_date)
ORDER BY one_time.order_date DESC
