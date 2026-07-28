# Data dictionary

## Source

**UCI Online Retail II** — [archive.ics.uci.edu/dataset/502](https://archive.ics.uci.edu/dataset/502/online+retail+ii), CC BY 4.0.

1,067,371 transaction lines from a UK-based online gift retailer,
2009-12-01 to 2011-12-09, delivered as a two-sheet Excel workbook.

| Sheet | Rows | Range |
|---|---|---|
| `Year 2009-2010` | 525,461 | 2009-12-01 → 2010-12-09 |
| `Year 2010-2011` | 541,910 | 2010-12-01 → 2011-12-09 |

Note the **nine-day overlap**: both sheets contain 2010-12-01 → 2010-12-09.
See [validation.md](validation.md) for how it is resolved.

### Source columns

| Column | Type | Notes |
|---|---|---|
| `Invoice` | text | Leading `C` marks a cancellation/return |
| `StockCode` | text | Real SKUs match `^[0-9]{5}`; others are service lines |
| `Description` | text | Missing on some rows; inconsistent spelling per SKU |
| `Quantity` | integer | Negative on returns |
| `InvoiceDate` | timestamp | |
| `Price` | numeric | Unit price in GBP; zero or negative on adjustments |
| `Customer ID` | integer | **NULL on ~20% of rows** (guest checkout) |
| `Country` | text | Ship-to country; includes non-countries |

---

## `staging` schema

### `staging.online_retail_raw`

Verbatim landing table. Permissive types, no constraints — a load must never
fail on a data problem, because problems are found by the assertions in
`sql/07_data_quality.sql`, not by a broken `COPY`.

Adds one column not in the source: `source_sheet`, which preserves workbook
provenance so the sheet overlap stays provable after de-duplication.

---

## `core` schema — star schema

### `core.dim_date`

Contiguous daily calendar covering **whole calendar years** (2009-01-01 →
2011-12-31), not just the observed range. Power BI time-intelligence functions
return blank against a date table with gaps or partial years.

| Column | Type | Notes |
|---|---|---|
| `date_key` | integer | `yyyymmdd`, PK |
| `full_date` | date | Marked as the model's date column |
| `year`, `quarter`, `month` | smallint | |
| `quarter_name`, `year_quarter` | text | `Q1`, `2010-Q1` |
| `month_name`, `month_short` | text | Sorted by `month`, not alphabetically |
| `year_month` | char(7) | `2010-01` — sorts correctly as text |
| `month_start`, `month_end` | date | |
| `day_of_month`, `day_of_week` | smallint | ISO: 1 = Monday |
| `day_name`, `day_short` | text | |
| `week_of_year`, `day_of_year` | smallint | |
| `is_weekend` | boolean | |
| `is_complete_month` | boolean | **FALSE for Dec 2011** — the partial month |

### `core.dim_product`

| Column | Type | Notes |
|---|---|---|
| `product_key` | integer | Surrogate PK |
| `stock_code` | text | Upper-cased, trimmed |
| `description` | text | Most frequent non-null spelling per SKU |
| `product_category` | text | **DERIVED** by keyword heuristic — see below |
| `is_service_line` | boolean | TRUE when `stock_code !~ '^[0-9]{5}'` |

`product_category` is not in the source. It is a documented keyword heuristic
whose only job is to give the report a Category → Product drill path. It is
approximate and labelled as such in the report. Categories: Christmas,
Bags & Wrap, Candles & Lighting, Kitchen & Dining, Garden & Outdoor,
Stationery & Craft, Toys & Games, Home Decor, Jewellery & Accessories, Other,
Uncategorised, Service / Adjustment.

### `core.dim_customer`

| Column | Type | Notes |
|---|---|---|
| `customer_key` | integer | PK. **-1 = Guest / Unknown** |
| `customer_id` | integer | NULL on the guest member |
| `customer_label` | text | |
| `country_key` | integer | Customer's most frequent ship-to country |
| `is_known_customer` | boolean | FALSE only for key -1 |

The guest member exists so the fact's foreign key can stay `NOT NULL` and
Power BI never silently drops that revenue from customer-sliced visuals.

### `core.dim_country`

| Column | Type | Notes |
|---|---|---|
| `country_key` | integer | Surrogate PK |
| `country_name` | text | As it appears in the source |
| `country_clean` | text | `EIRE`→Ireland, `RSA`→South Africa, `USA`→United States |
| `iso2` | char(2) | NULL for `Unspecified` / `European Community` |
| `region` | text | UK, Europe, Middle East, Asia Pacific, Americas, Africa |
| `is_domestic` | boolean | TRUE for United Kingdom |

### `core.fact_sales`

Grain: **one row per invoice line.**

| Column | Type | Notes |
|---|---|---|
| `sale_key` | bigint | Surrogate PK |
| `invoice_no`, `invoice_line` | text, smallint | |
| `date_key`, `invoice_ts` | integer, timestamp | |
| `product_key`, `customer_key`, `country_key` | integer | All NOT NULL |
| `quantity` | integer | Negative on returns |
| `unit_price` | numeric(12,4) | Always > 0 |
| `line_revenue` | numeric(14,4) | `quantity * unit_price` |
| `is_return` | boolean | Invoice starts `C`, or quantity < 0 |
| `is_first_order` | boolean | TRUE on every line of a customer's first invoice |

Returns are **kept** with negative revenue, so `SUM(line_revenue)` is net.

### `core.fact_sales_exclusions`

Reconciliation ledger. Every staging row is either in the fact or counted here
under a named reason: `duplicate_row`, `service_line`, `non_positive_price`,
`zero_quantity`, `missing_key_field`.

---

## `analytics` schema — the Power BI surface

Power BI connects **only** to this schema.

| View | Grain | Purpose |
|---|---|---|
| `vw_dim_date` | day | Imported as the model's date table |
| `vw_dim_product` | SKU | Service lines filtered out |
| `vw_dim_customer` | customer | |
| `vw_dim_country` | country | |
| `vw_fact_sales` | invoice line | |
| `vw_kpi_summary` | 1 row | Headline KPIs; cross-checks the DAX cards |
| `vw_monthly_sales` | month | MoM, YoY, 3-month moving average, YTD |
| `vw_daily_sales` | day | 7-day and 30-day moving averages |
| `vw_product_performance` | SKU | Rank, revenue share, ABC (Pareto) class |
| `vw_country_performance` | country | Rank and revenue share |
| `vw_customer_rfm` | customer | R/F/M quintiles and segment |
| `vw_cohort_retention` | cohort × month | Retention triangle |
| `vw_returns_analysis` | month × category | Return rate over time |
| `vw_data_quality` | 1 row per check | PASS/FAIL assertions |
