# Validation

Several DAX measures deliberately duplicate a SQL view. That redundancy is the
test. A Power BI measure with a subtly wrong filter context produces a dashboard
that looks completely normal and reports the wrong number — the only way to
catch it is to compute the same figure twice, independently, and compare.

Every figure below was read off the rendered report and re-derived in SQL.

---

## Setup

The report applies `dim_date[is_complete_month] = TRUE` as a page filter, so it
excludes December 2011 — the month the extract stops nine days into. The SQL
comparisons must apply the same filter or they will not agree:

```sql
SELECT
    ROUND(SUM(f.line_revenue), 2)                                   AS net_revenue,
    COUNT(DISTINCT f.invoice_no) FILTER (WHERE NOT f.is_return)     AS total_orders,
    COUNT(DISTINCT f.customer_key) FILTER (WHERE f.customer_key <> -1) AS active_customers,
    ROUND(SUM(f.line_revenue)
          / NULLIF(COUNT(DISTINCT f.invoice_no) FILTER (WHERE NOT f.is_return), 0), 2)
                                                                    AS avg_order_value,
    ROUND(ABS(SUM(f.line_revenue) FILTER (WHERE f.is_return))
          / NULLIF(SUM(f.line_revenue) FILTER (WHERE NOT f.is_return), 0) * 100, 2)
                                                                    AS return_rate_pct,
    SUM(f.quantity)                                                 AS units_sold
FROM core.fact_sales f
JOIN core.dim_date d ON d.date_key = f.date_key
WHERE d.is_complete_month;
```

## Headline KPIs

| Measure | Power BI | PostgreSQL | Match |
|---|---:|---:|:--:|
| `[Net Revenue]` | £18M (card) / £18,485,318 (matrix total) | 18,485,318.06 | ✅ |
| `[Total Orders]` | 39K (card) / 38,700 (matrix total) | 38,700 | ✅ |
| `[Active Customers]` | 5,847 | 5,847 | ✅ |
| `[Avg Order Value]` | £477.66 | 477.66 | ✅ |
| `[Return Rate %]` | 2.9% | 2.85% | ✅ (display rounding) |
| `[Units Sold]` | 10M (card) / 10,490,624 (matrix total) | 10,490,624 | ✅ |
| `[Revenue per Customer]` | £3,162 | 3,161.68 | ✅ |
| `[Repeat Rate %]` | 75.8% | 75.8% | ✅ |

The KPI cards abbreviate to 2–3 significant figures, so the unrounded
cross-check comes from the Product Performance matrix total row, which prints
full precision.

## Time intelligence

`[Revenue YoY %]` vs `analytics.vw_monthly_sales.yoy_growth_pct`:

| Month | SQL `yoy_growth_pct` | SQL `revenue_3mo_moving_avg` |
|---|---:|---:|
| 2010-12 | −2.59% | 1,073,795.16 |
| 2011-05 | +20.56% | 630,731.39 |
| 2011-09 | +20.18% | 796,446.96 |
| 2011-11 | +2.30% | 1,166,538.45 |

```sql
SELECT year_month, net_revenue, yoy_growth_pct, revenue_3mo_moving_avg
FROM analytics.vw_monthly_sales
ORDER BY month_start;
```

Two things this catches:

**The first year must be blank, not +100%.** `vw_monthly_sales` returns NULL for
`yoy_growth_pct` across 2009-12 → 2010-11 because `LAG(..., 12)` has no prior
row. `[Revenue YoY]` wraps its subtraction in `IF ( NOT ISBLANK ( Prior ), ... )`
for the same reason — without it, DAX treats BLANK as zero and every month of
the first year reports growth equal to its own revenue.

**The 3-month average must average months, not days.** `[Revenue 3M Moving Avg]`
iterates `VALUES ( dim_date[year_month] )` inside the window. Iterating the
window's ~90 dates instead returns an average *daily* figure roughly thirty
times smaller — a mistake that plots as a flat line near zero and is easy to
miss on a chart with a large y-axis.

## Moving averages, daily grain

| Date | Net revenue | `revenue_7d_moving_avg` |
|---|---:|---:|
| 2011-09-15 | 74,031.30 | 34,828.54 |
| 2011-11-30 | 55,150.65 | 41,331.82 |

The SQL view builds its window from `core.dim_date`, so non-trading days enter
the average as zero rather than being skipped. `[Revenue 7D Moving Avg]`
reproduces that with `[Net Revenue] + 0` — this retailer does not trade
Saturdays, and `AVERAGEX` skips BLANK, so without the coercion the divisor is 6
instead of 7 and the average runs ~17% high.

## Warehouse integrity

`sql/07_data_quality.sql` — 11 assertions, all passing:

```
reconciliation: staging = fact + exclusions   PASS  staging=1067371 fact=1021126 excluded=46245
no duplicate invoice lines in fact            PASS  0 natural keys appear more than once
dim_date is contiguous                        PASS  1095 rows spanning 2009-01-01..2011-12-31
monthly series is dense                       PASS  25 distinct trading months
line_revenue = quantity * unit_price          PASS  0 mismatched rows
fact contains no service lines                PASS
guest member (-1) exists and carries revenue  PASS  226965 guest rows, 2567651.64 net revenue
no NULLs in fact measures or keys             PASS
return rate is plausible (0-25%)              PASS  3.65%
no orphan dimension keys                      PASS
at least two calendar years of sales          PASS  years present: 2009, 2010, 2011
```

Row reconciliation closes exactly:

```
1,021,126  fact_sales
   34,337  duplicate_row        (sheet overlap 2010-12-01..09 + exact repeats)
    5,980  service_line         (postage, discounts, bank charges, test rows)
    5,928  non_positive_price   (giveaways, bad-debt write-offs)
─────────
1,067,371  staging rows         ✅ equals the source row count
```

Note the two return-rate figures. The 3.65% in the assertion is over the whole
extract; the 2.85% on the dashboard excludes the partial December 2011, which
carried an unusually high return share. Both are correct for their scope — this
is exactly the kind of discrepancy that looks like a bug until you check the
filter.

## Analytical outputs

**ABC / Pareto** — the classic concentration holds:

| Class | SKUs | Share of revenue |
|---|---:|---:|
| A | 1,038 | 80.0% |
| B | 1,255 | 15.0% |
| C | 2,428 | 5.0% |

22% of SKUs generate 80% of revenue.

**RFM segments** — scored against the last date in the extract, not today:

| Segment | Customers | Revenue |
|---|---:|---:|
| Champions | 1,302 | £11,376,814 |
| Loyal | 1,348 | £2,497,874 |
| At Risk – High Value | 253 | £926,746 |
| At Risk | 595 | £518,547 |
| Lost | 883 | £339,405 |
| New / Promising | 460 | £253,597 |
| Hibernating | 603 | £247,252 |
| Needs Attention | 388 | £200,783 |

1,302 Champions — 22% of scored customers — account for 68% of attributable
revenue. The 253 "At Risk – High Value" accounts are the actionable segment:
high past spend, no recent orders.

## Reproducing this

```bash
psql -U postgres -d retail_analytics -c "SELECT * FROM analytics.vw_data_quality ORDER BY status DESC, check_name;"
```

```bash
psql -U postgres -d retail_analytics -c "SELECT * FROM analytics.vw_kpi_summary;"
```
