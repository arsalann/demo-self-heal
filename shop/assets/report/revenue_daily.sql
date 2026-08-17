/* @bruin
name: shop_report.revenue_daily
type: bq.sql
connection: gcp-default
description: >
  Daily storefront revenue broken down by country and product category. One row
  per (order_date, country, category). Joins conformed orders to the conformed
  product catalog, so the product-category rename in the source is already
  normalized away. This is Finance's slice-and-dice revenue table.

depends:
  - shop_stage.orders_clean
  - shop_stage.products_clean

materialization:
  type: table
  strategy: create+replace
  partition_by: order_date
  cluster_by:
    - country

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

columns:
  - name: order_date
    type: DATE
    description: UTC calendar date of the orders.
    primary_key: true
    nullable: false
    checks:
      - name: not_null
  - name: country
    type: VARCHAR
    description: ISO 3166-1 alpha-2 country code.
    primary_key: true
    nullable: false
  - name: category
    type: VARCHAR
    description: Product category, normalized in the stage layer.
    primary_key: true
    nullable: false
  - name: order_count
    type: INTEGER
    description: Number of orders in the slice.
    checks:
      - name: positive
  - name: distinct_users
    type: INTEGER
    description: Number of distinct customers in the slice.
    checks:
      - name: positive
  - name: revenue_usd
    type: DOUBLE
    description: Gross order revenue in USD for the slice.
    checks:
      - name: positive

custom_checks:
  - name: no_day_has_zero_revenue
    description: >
      Every order_date present in the table must have positive total revenue. A
      day that sums to zero points to a freshness or ingest problem upstream.
    query: |
      SELECT COUNT(*)
      FROM (
        SELECT order_date
        FROM {{ this }}
        GROUP BY order_date
        HAVING SUM(revenue_usd) = 0
      )
    value: 0
    blocking: true

unit_tests:
  - name: joins_orders_to_categories_and_sums_revenue
    description: >
      Two same-day, same-country, same-category orders should collapse to one row
      with the order count, distinct users, and summed revenue.
    inputs:
      - asset: shop_stage.orders_clean
        rows:
          - {order_id: O1, user_id: U1, product_id: P001, country: US, amount_usd: 100.0, created_at: "2026-05-01 10:00:00", order_date: "2026-05-01"}
          - {order_id: O2, user_id: U2, product_id: P002, country: US, amount_usd: 50.0, created_at: "2026-05-01 11:00:00", order_date: "2026-05-01"}
      - asset: shop_stage.products_clean
        rows:
          - {product_id: P001, name: "Throw Blanket", category: home, price_usd: 100.0}
          - {product_id: P002, name: "Ceramic Mug", category: home, price_usd: 50.0}
    expected:
      match: exact
      rows:
        - {order_date: "2026-05-01", country: US, category: home, order_count: 2, distinct_users: 2, revenue_usd: 150.0}

@bruin */

SELECT
    orders.order_date,
    orders.country,
    COALESCE(products.category, 'unknown') AS category,
    COUNT(*) AS order_count,
    COUNT(DISTINCT orders.user_id) AS distinct_users,
    ROUND(SUM(orders.amount_usd), 2) AS revenue_usd
FROM shop_stage.orders_clean AS orders
LEFT JOIN shop_stage.products_clean AS products
    ON orders.product_id = products.product_id
GROUP BY 1, 2, 3
ORDER BY 1 DESC, 6 DESC
