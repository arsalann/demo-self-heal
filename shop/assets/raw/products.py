"""@bruin
name: shop_raw.products
type: python
image: python:3.11
connection: gcp-default
description: |
  Raw product catalog, re-emitted in full on every run with an extraction
  timestamp. Source-faithful and append-only; `shop_stage.products_clean` keeps
  the latest row per product.

  This asset emulates the catalog source with a deterministic generator and seeds
  one designed incident:

    Schema drift (column rename) — before 2026-05-18 the category column is named
    `category`; from 2026-05-18 the same values are emitted under
    `product_category`. `shop_stage.products_clean` normalizes either name to
    `category`, so the report layer never sees the rename.

materialization:
  type: table
  strategy: append

owner: dana@harborside.example
tags:
  - harborside
  - shop
  - raw
  - products
domains:
  - commerce
meta:
  layer: raw
  tier: bronze
  team: finance
  cost_center: FIN-204
  source: harborside-api products (emulated)
  contains_incidents: "schema-drift-column-rename"

columns:
  - name: product_id
    type: VARCHAR
    description: Product identifier.
    primary_key: true
    nullable: false
    checks:
      - name: not_null
  - name: name
    type: VARCHAR
    description: Product display name.
    nullable: false
  - name: category
    type: VARCHAR
    description: >
      Product category. Pre-drift column name; from 2026-05-18 the source renames
      it to `product_category`. Nullable here because only one of the two names is
      present at a time.
  - name: price_usd
    type: DOUBLE
    description: List price in USD.
    nullable: false
    checks:
      - name: positive
  - name: extracted_at
    type: TIMESTAMP
    description: UTC timestamp when this catalog snapshot was generated.
    nullable: false

custom_checks:
  - name: category_or_product_category_present
    description: >
      The live products table must expose either `category` or the drifted
      `product_category` column, so the stage normalization has something to read.
    query: |
      SELECT IF(COUNT(*) = 0, 1, 0)
      FROM shop_raw.INFORMATION_SCHEMA.COLUMNS
      WHERE table_name = 'products'
        AND column_name IN ('category', 'product_category')
    value: 0
    blocking: false

@bruin"""

import os
import random
from datetime import date, datetime, timezone

import pandas as pd

CATEGORIES = ["apparel", "electronics", "home", "books", "outdoors", "beauty"]
DRIFT_DATE = date(2026, 5, 18)


def materialize():
    rng = random.Random(42)
    rows = []
    for i in range(1, 31):
        rows.append({
            "product_id": f"P{i:03d}",
            "name": f"Product {i:03d}",
            "category": rng.choice(CATEGORIES),
            "price_usd": round(rng.uniform(10, 400), 2),
        })

    df = pd.DataFrame(rows)
    df["extracted_at"] = datetime.now(timezone.utc).replace(tzinfo=None)
    df["extracted_at"] = pd.to_datetime(df["extracted_at"]).astype("datetime64[us]")

    end_str = os.environ.get("BRUIN_END_DATE", date.today().isoformat())
    end = date.fromisoformat(end_str[:10])

    if end >= DRIFT_DATE:
        df = df.rename(columns={"category": "product_category"})
        print(f"[shop] schema drift active: 'category' -> 'product_category' (end_date={end})")

    print(f"[shop] emitted {len(df)} products with columns {list(df.columns)}")
    return df
