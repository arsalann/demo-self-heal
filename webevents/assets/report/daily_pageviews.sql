/* @bruin
name: webevents_report.daily_pageviews
type: bq.sql
connection: gcp-default
description: >
  Daily pageview totals broken down by country and browser. One row per
  (event_date, country, browser). This is the traffic surface marketing watches
  for anomalies and new segments: the 2026-05-18 Indonesia spike and the Arc
  browser appearing from 2026-05-16 both show up here.

depends:
  - webevents_stage.pageviews_clean

materialization:
  type: table
  strategy: create+replace
  partition_by: event_date
  cluster_by:
    - country

owner: priya@harborside.example
tags:
  - harborside
  - webevents
  - report
  - traffic
domains:
  - marketing
meta:
  layer: report
  tier: gold
  team: growth
  cost_center: MKT-330
  sla: "07:00 UTC"

columns:
  - name: event_date
    type: DATE
    description: UTC calendar date of the pageviews.
    primary_key: true
    nullable: false
    checks:
      - name: not_null
  - name: country
    type: VARCHAR
    description: ISO 3166-1 alpha-2 country code.
    primary_key: true
    nullable: false
  - name: browser
    type: VARCHAR
    description: Browser name.
    primary_key: true
    nullable: false
  - name: pageviews
    type: INTEGER
    description: Number of pageviews in the slice.
    checks:
      - name: positive
  - name: distinct_sessions
    type: INTEGER
    description: Number of distinct sessions in the slice.
    checks:
      - name: positive
  - name: distinct_users
    type: INTEGER
    description: Number of distinct users in the slice.
    checks:
      - name: positive

custom_checks:
  - name: known_browsers_only
    description: >
      Browser values should stay within the supported set. A new value is a
      contract signal (a segment downstream code may not handle), not a bad row to
      delete. The Arc browser from 2026-05-16 trips this as a warning.
    query: |
      SELECT COUNT(*)
      FROM {{ this }}
      WHERE browser NOT IN ('Chrome', 'Safari', 'Firefox', 'Edge', 'Arc')
    value: 0
    blocking: false

@bruin */

SELECT
    event_date,
    country,
    browser,
    COUNT(*) AS pageviews,
    COUNT(DISTINCT session_id) AS distinct_sessions,
    COUNT(DISTINCT user_id) AS distinct_users
FROM webevents_stage.pageviews_clean
GROUP BY 1, 2, 3
ORDER BY 1 DESC, 4 DESC
