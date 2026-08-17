/* @bruin
name: webevents_report.traffic_conversion_daily
type: bq.sql
connection: gcp-default
description: >
  Daily traffic-to-order conversion: sessions and pageviews from the marketing
  side next to storefront orders from the shop pipeline, with a conversion rate.
  One row per date. The order count comes from `shop_stage.orders_clean` across a
  pipeline boundary, but the dependency is declared `symbolic`: this is
  operational marketing monitoring that must run on schedule even if shop is late,
  showing conversion against whatever order data has landed rather than blocking.

depends:
  - webevents_stage.pageviews_clean
  - uri: bigquery://harborside-analytics.shop_stage.orders_clean
    mode: symbolic

materialization:
  type: table
  strategy: create+replace
  partition_by: event_date

owner: priya@harborside.example
tags:
  - harborside
  - webevents
  - report
  - conversion
  - cross-pipeline
domains:
  - marketing
meta:
  layer: report
  tier: gold
  team: growth
  cost_center: MKT-330
  sla: "07:30 UTC"
  cross_pipeline_upstream: shop
  contract: symbolic (non-blocking) on shop_stage.orders_clean

columns:
  - name: event_date
    type: DATE
    description: UTC calendar date. Grain is one row per day.
    primary_key: true
    nullable: false
    checks:
      - name: not_null
      - name: unique
  - name: pageviews
    type: INTEGER
    description: Total pageviews that day.
    checks:
      - name: non_negative
  - name: distinct_sessions
    type: INTEGER
    description: Distinct sessions that day.
    checks:
      - name: non_negative
  - name: order_count
    type: INTEGER
    description: Storefront orders that day, from the shop pipeline.
    checks:
      - name: non_negative
  - name: conversion_rate
    type: FLOAT64
    description: order_count divided by distinct_sessions. Null on days with no sessions.
    checks:
      - name: min
        value: 0

unit_tests:
  - name: computes_conversion_from_sessions_and_orders
    description: >
      Three pageviews over two sessions with one order should give a conversion
      rate of 0.5.
    inputs:
      - asset: webevents_stage.pageviews_clean
        rows:
          - {session_id: S1, event_date: "2026-05-01"}
          - {session_id: S1, event_date: "2026-05-01"}
          - {session_id: S2, event_date: "2026-05-01"}
      - asset: shop_stage.orders_clean
        rows:
          - {order_id: O1, order_date: "2026-05-01"}
    expected:
      match: exact
      rows:
        - {event_date: "2026-05-01", pageviews: 3, distinct_sessions: 2, order_count: 1, conversion_rate: 0.5}

@bruin */

WITH sessions AS (
    SELECT
        event_date,
        COUNT(*) AS pageviews,
        COUNT(DISTINCT session_id) AS distinct_sessions
    FROM webevents_stage.pageviews_clean
    GROUP BY 1
),

orders AS (
    SELECT
        order_date,
        COUNT(*) AS order_count
    FROM shop_stage.orders_clean
    GROUP BY 1
)

SELECT
    sessions.event_date,
    sessions.pageviews,
    sessions.distinct_sessions,
    COALESCE(orders.order_count, 0) AS order_count,
    SAFE_DIVIDE(orders.order_count, sessions.distinct_sessions) AS conversion_rate
FROM sessions
LEFT JOIN orders
    ON sessions.event_date = orders.order_date
ORDER BY sessions.event_date DESC
