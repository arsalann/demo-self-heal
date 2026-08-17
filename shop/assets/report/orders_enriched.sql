/* @bruin
# Reference asset — every asset-level Bruin feature in one file.

name: shop_report.orders_enriched
type: bq.sql
connection: gcp-default
uri: bigquery://harborside-analytics.shop_report.orders_enriched   # cross-pipeline address

description: >
  Order-grain fact enriched for analysis: one row per order with its product
  category, whether the buyer is a billing customer, and how they were acquired.

depends:                                                   # 3 dependency kinds:
  - shop_stage.orders_clean                                # regular (blocking)
  - asset: shop_stage.products_clean                       # symbolic (lineage only)
    mode: symbolic
  - uri: bigquery://harborside-analytics.stripe_stage.customers   # external (cross-pipeline)

materialization:
  type: table
  strategy: time_interval          # rebuilds one interval per run
  incremental_key: order_date
  time_granularity: date
  partition_by: order_date
  cluster_by:
    - country

interval_modifiers:
  start: -2h                        # source runs late: shift start back 2h

owner: dana@harborside.example
tags:
  - harborside
  - shop
  - report
  - reference
domains:
  - commerce
  - finance
meta:
  layer: report
  tier: gold
  team: finance
  cost_center: FIN-204
  sla: "06:30 UTC"
  grain: one row per order

columns:
  - name: order_id
    extends: Order.OrderId          # pull type/description from glossary
    type: VARCHAR
    description: Storefront order identifier; the grain.
    primary_key: true
    nullable: false
    checks:
      - name: not_null
      - name: unique
  - name: order_date
    extends: Order.OrderDate
    type: DATE
    description: UTC calendar date of the order.
    nullable: false
    # update_on_merge: true         # merge strategy only
    checks:
      - name: not_null
  - name: country
    extends: Order.Country
    type: VARCHAR
    description: ISO 3166-1 alpha-2 country code.
    checks:
      - name: pattern
        value: "^[A-Z]{2}$"
  - name: product_id
    extends: Product.ProductId
    type: VARCHAR
    description: Product ordered.
    foreign_key:                    # parent for the relationships check
      table: shop_stage.products_clean
      column: product_id
    checks:
      - name: not_null
      - name: relationships
  - name: category
    extends: Product.Category
    type: VARCHAR
    description: Product category, from the catalog.
    checks:
      - name: accepted_values
        value: [apparel, electronics, home, books, outdoors, beauty, unknown]
  - name: amount_usd
    extends: Order.AmountUsd
    type: DOUBLE
    description: Order gross amount in USD.
    checks:
      - name: positive
  - name: billing_customer_id
    extends: Customer.CustomerId
    type: VARCHAR
    description: Matched Stripe customer, null if none.
    nullable: true
  - name: is_billing_customer
    type: BOOL
    description: Whether the buyer has a Stripe billing account.
  - name: acquisition_channel
    type: VARCHAR
    description: How the customer was acquired, from billing.
    nullable: true

custom_checks:
  - name: no_non_positive_amounts     # custom SQL check: query result must equal value
    description: Every order must have a positive amount.
    query: SELECT COUNT(*) FROM {{ this }} WHERE amount_usd <= 0
    value: 0
    blocking: true

unit_tests:                           # one order in -> assert its category
  - name: order_gets_its_product_category
    inputs:
      - asset: shop_stage.orders_clean
        rows:
          - {order_id: O1, product_id: P1, order_date: "2026-05-01"}
      - asset: shop_stage.products_clean
        rows:
          - {product_id: P1, category: home}
    expected:
      rows:
        - {order_id: O1, category: home}
@bruin */

WITH orders_in_interval AS (
    SELECT
        order_id,
        order_date,
        country,
        product_id,
        user_id,
        amount_usd
    FROM shop_stage.orders_clean
    WHERE order_date BETWEEN DATE('{{ start_date }}') AND DATE('{{ end_date }}')
)

SELECT
    orders.order_id,
    orders.order_date,
    orders.country,
    orders.product_id,
    COALESCE(products.category, 'unknown') AS category,
    orders.amount_usd,
    customers.stripe_customer_id AS billing_customer_id,
    customers.stripe_customer_id IS NOT NULL AS is_billing_customer,
    customers.acquisition_channel
FROM orders_in_interval AS orders
LEFT JOIN shop_stage.products_clean AS products
    ON orders.product_id = products.product_id
-- Demo identity mapping: user_id -> Stripe customer id
LEFT JOIN stripe_stage.customers AS customers
    ON orders.user_id = customers.stripe_customer_id
