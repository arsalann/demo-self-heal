/* @bruin
name: webevents_stage.pageviews_clean
type: bq.sql
connection: gcp-default
description: >
  Cleaned pageview events, one row per event. Deduplicates the append-only raw
  table on the full event key, keeping the latest copy by inserted_at, so replayed
  ingestions do not double-count traffic. This is the conformed event stream the
  marketing reports build on.

depends:
  - webevents_raw.pageviews

materialization:
  type: table
  strategy: create+replace
  partition_by: event_date
  cluster_by:
    - country
    - browser

owner: priya@harborside.example
tags:
  - harborside
  - webevents
  - stage
  - traffic
domains:
  - marketing
meta:
  layer: stage
  tier: silver
  team: growth
  cost_center: MKT-330
  grain: one row per pageview event

columns:
  - name: session_id
    type: VARCHAR
    description: Session identifier.
    nullable: false
    checks:
      - name: not_null
  - name: user_id
    type: VARCHAR
    description: User identifier (anonymous id if not logged in).
    nullable: false
  - name: country
    type: VARCHAR
    description: ISO 3166-1 alpha-2 country code.
    nullable: false
  - name: browser
    type: VARCHAR
    description: Browser name.
    nullable: false
  - name: device
    type: VARCHAR
    description: Device class.
    checks:
      - name: accepted_values
        value: [desktop, mobile, tablet]
  - name: page_path
    type: VARCHAR
    description: URL path of the pageview.
    nullable: false
  - name: event_time
    type: TIMESTAMP
    description: Pageview timestamp (UTC).
    nullable: false
  - name: event_date
    type: DATE
    description: Pageview date (UTC, derived). Grain partition column.
    nullable: false
    checks:
      - name: not_null

@bruin */

WITH raw_with_inserted_at AS (
    SELECT
        session_id,
        user_id,
        country,
        browser,
        device,
        page_path,
        event_time,
        event_date,
        SAFE_CAST(JSON_VALUE(TO_JSON_STRING(raw_pageviews), '$.inserted_at') AS TIMESTAMP) AS inserted_at
    FROM webevents_raw.pageviews AS raw_pageviews
)

SELECT
    session_id,
    user_id,
    country,
    browser,
    device,
    page_path,
    event_time,
    event_date
FROM raw_with_inserted_at
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY session_id, user_id, country, browser, device, page_path, event_time, event_date
    ORDER BY inserted_at DESC NULLS LAST
) = 1
