/* @bruin
name: shop_stage.products_clean
type: bq.sql
connection: gcp-default
description: >
  Conformed product catalog: one row per product, latest version. Normalizes the
  category column whether the source sends it as `category` (before the rename)
  or `product_category` (after), so downstream reports never see the drift.
  Deduplicates by product_id keeping the latest row by extracted_at.

depends:
  - shop_raw.products

materialization:
  type: table
  strategy: create+replace

owner: dana@harborside.example
tags:
  - harborside
  - shop
  - stage
  - products
domains:
  - commerce
meta:
  layer: stage
  tier: silver
  team: finance
  cost_center: FIN-204
  grain: one row per product

columns:
  - name: product_id
    type: VARCHAR
    description: Product identifier. Unique after deduplication.
    primary_key: true
    nullable: false
    checks:
      - name: not_null
      - name: unique
  - name: name
    type: VARCHAR
    description: Product display name.
  - name: category
    type: VARCHAR
    description: >
      Product category, normalized from either source column name. `unknown`
      when the source omitted it.
    checks:
      - name: not_null
      - name: accepted_values
        value: [apparel, electronics, home, books, outdoors, beauty, unknown]
  - name: price_usd
    type: DOUBLE
    description: List price in USD.
    checks:
      - name: positive

@bruin */

SELECT
    product_rows.product_id,
    product_rows.name,
    COALESCE(
        JSON_VALUE(TO_JSON_STRING(product_rows), '$.product_category'),
        JSON_VALUE(TO_JSON_STRING(product_rows), '$.category'),
        'unknown'
    ) AS category,
    product_rows.price_usd
FROM shop_raw.products AS product_rows
WHERE product_rows.product_id IS NOT NULL
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY product_rows.product_id
    ORDER BY product_rows.extracted_at DESC
) = 1
