# DAX measures

Every measure in the report, with the reasoning behind it. These are the same
definitions that live in
`powerbi/RetailAnalytics.SemanticModel/definition/tables/_Measures.tmdl` — this
file is the readable version, the TMDL is what Power BI loads.

Measures sit on a dedicated empty table called `_Measures` so they group in one
place in the field list instead of scattering across the fact and dimensions.

Model shape (single-direction filters, one-to-many from every dimension):

```
dim_date ─┐
dim_product ─┼──> fact_sales
dim_customer ─┤
dim_country ─┘
```

---

## 1. Base measures

```dax
Net Revenue =
SUM ( fact_sales[line_revenue] )
```

Net of returns, because returns carry a negative `line_revenue`. This is the
headline number on the dashboard. Reporting gross instead would overstate every
KPI by the return rate — roughly 2% overall, but far more on some categories.

```dax
Gross Revenue =
CALCULATE ( [Net Revenue], fact_sales[is_return] = FALSE )
```

```dax
Returned Revenue =
ABS ( CALCULATE ( [Net Revenue], fact_sales[is_return] = TRUE ) )
```

`ABS` so the card reads as a positive magnitude. The sign is already carried by
the flag.

```dax
Return Rate % =
DIVIDE ( [Returned Revenue], [Gross Revenue] )
```

`DIVIDE` rather than `/` throughout — it returns BLANK on a zero denominator
instead of an error, which matters as soon as a slicer narrows to a period with
no gross sales.

```dax
Total Orders =
CALCULATE (
    DISTINCTCOUNT ( fact_sales[invoice_no] ),
    fact_sales[is_return] = FALSE
)
```

Sales invoices only. A credit note is not an order; counting it as one inflates
the denominator of average order value. `analytics.vw_kpi_summary` applies the
identical filter, which is what lets the two be compared directly.

```dax
Return Invoices =
CALCULATE (
    DISTINCTCOUNT ( fact_sales[invoice_no] ),
    fact_sales[is_return] = TRUE
)
```

```dax
Units Sold =
SUM ( fact_sales[quantity] )
```

```dax
Active Customers =
CALCULATE (
    DISTINCTCOUNT ( fact_sales[customer_key] ),
    fact_sales[customer_key] <> -1
)
```

Key −1 is the guest member. Its revenue is real and stays in `[Net Revenue]`,
but it is a single synthetic member and would otherwise register as one
"customer" worth about a fifth of the business.

```dax
Avg Order Value =
DIVIDE ( [Net Revenue], [Total Orders] )
```

```dax
Avg Basket Size =
DIVIDE ( [Units Sold], [Total Orders] )
```

```dax
Revenue per Customer =
DIVIDE ( [Net Revenue], [Active Customers] )
```

---

## 2. New vs returning customers

```dax
New Customers =
CALCULATE (
    DISTINCTCOUNT ( fact_sales[customer_key] ),
    fact_sales[is_first_order] = TRUE,
    fact_sales[customer_key] <> -1
)
```

```dax
Returning Customers =
[Active Customers] - [New Customers]
```

`is_first_order` is precomputed in SQL (`sql/04_transform_facts.sql`) rather
than derived in DAX. The usual DAX approach —

```dax
// deliberately NOT used
New Customers =
COUNTROWS (
    FILTER (
        VALUES ( fact_sales[customer_key] ),
        CALCULATE ( MIN ( fact_sales[invoice_ts] ), ALLEXCEPT ( fact_sales, fact_sales[customer_key] ) )
            >= MIN ( dim_date[full_date] )
    )
)
```

— re-scans the fact for every customer in every visual. Pushing it to a boolean
column computed once at load turns an expensive iterator into a filter the
storage engine handles directly.

---

## 3. Time intelligence — year over year

```dax
Net Revenue LY =
CALCULATE ( [Net Revenue], SAMEPERIODLASTYEAR ( dim_date[full_date] ) )
```

```dax
Revenue YoY =
VAR Current = [Net Revenue]
VAR Prior   = [Net Revenue LY]
RETURN IF ( NOT ISBLANK ( Prior ), Current - Prior )
```

The `IF` matters. Without it, every month of 2009–2010 shows a YoY equal to its
own revenue, because subtracting BLANK yields the full current value and the
first year of any dataset has no prior year to compare against. That produces a
column chart with a fake +100% wall across the entire first year.

```dax
Revenue YoY % =
VAR Prior = [Net Revenue LY]
RETURN DIVIDE ( [Revenue YoY], ABS ( Prior ) )
```

`ABS` on the denominator keeps the sign of the growth correct if a prior period
ever nets negative (possible for a single product in a heavy return month —
without it, a recovery from −5,000 to −1,000 reports as a decline).

```dax
Orders LY =
CALCULATE ( [Total Orders], SAMEPERIODLASTYEAR ( dim_date[full_date] ) )
```

```dax
Orders YoY % =
DIVIDE ( [Total Orders] - [Orders LY], [Orders LY] )
```

### The partial-month trap

The extract ends **2011-12-09**. December 2011 therefore holds nine trading
days and December 2010 holds thirty-one. Compared naively, the dashboard
reports a catastrophic YoY collapse that never happened.

`dim_date[is_complete_month]` flags this, and the report applies it as a
page-level filter. The measure below makes the comparison honest when the
partial month is deliberately included:

```dax
Revenue YoY % (Like-for-Like) =
VAR LastTxnDate  = CALCULATE ( MAX ( fact_sales[invoice_ts] ), ALL ( fact_sales ) )
VAR CutoffDay    = DAY ( LastTxnDate )
VAR IsPartial    = MAX ( dim_date[month_end] ) > LastTxnDate
VAR PriorAligned =
    CALCULATE (
        [Net Revenue],
        SAMEPERIODLASTYEAR ( dim_date[full_date] ),
        dim_date[day_of_month] <= CutoffDay
    )
VAR Prior = IF ( IsPartial, PriorAligned, [Net Revenue LY] )
RETURN
    DIVIDE ( [Net Revenue] - Prior, ABS ( Prior ) )
```

When the visible month is complete this is identical to `[Revenue YoY %]`. When
it is partial, the prior-year comparison is clipped to the same day of the
month, so nine days of 2011 are compared against nine days of 2010.

```dax
Revenue YTD =
TOTALYTD ( [Net Revenue], dim_date[full_date] )
```

```dax
Revenue YTD LY =
CALCULATE ( [Revenue YTD], SAMEPERIODLASTYEAR ( dim_date[full_date] ) )
```

---

## 4. Time intelligence — month over month

```dax
Net Revenue PM =
CALCULATE ( [Net Revenue], DATEADD ( dim_date[full_date], -1, MONTH ) )
```

```dax
Revenue MoM % =
VAR Prior = [Net Revenue PM]
RETURN DIVIDE ( [Net Revenue] - Prior, ABS ( Prior ) )
```

---

## 5. Moving averages

```dax
Revenue 3M Moving Avg =
VAR Window =
    DATESINPERIOD ( dim_date[full_date], MAX ( dim_date[full_date] ), -3, MONTH )
RETURN
    CALCULATE (
        AVERAGEX ( VALUES ( dim_date[year_month] ), [Net Revenue] ),
        Window
    )
```

Iterating `VALUES ( dim_date[year_month] )` averages **months**, not days. The
common mistake is `AVERAGEX ( Window, [Net Revenue] )`, which iterates the ~90
individual dates in the window and returns an average *daily* figure roughly
thirty times smaller than the monthly line it is plotted against.

```dax
Revenue 7D Moving Avg =
VAR Window =
    DATESINPERIOD ( dim_date[full_date], MAX ( dim_date[full_date] ), -7, DAY )
RETURN
    CALCULATE (
        AVERAGEX ( VALUES ( dim_date[full_date] ), [Net Revenue] + 0 ),
        Window
    )
```

The `+ 0` is load-bearing. This retailer does not trade on Saturdays, so about
one day in seven has no rows and `[Net Revenue]` returns BLANK there.
`AVERAGEX` skips blanks, so without the `+ 0` the divisor is 6 rather than 7 and
the average runs about 17% high. Coercing to zero makes it a true 7-calendar-day
mean and matches `analytics.vw_daily_sales.revenue_7d_moving_avg` exactly.

```dax
Revenue 30D Moving Avg =
VAR Window =
    DATESINPERIOD ( dim_date[full_date], MAX ( dim_date[full_date] ), -30, DAY )
RETURN
    CALCULATE (
        AVERAGEX ( VALUES ( dim_date[full_date] ), [Net Revenue] + 0 ),
        Window
    )
```

---

## 6. Contribution and ranking

```dax
% of Total Revenue =
DIVIDE (
    [Net Revenue],
    CALCULATE ( [Net Revenue], REMOVEFILTERS ( dim_product ), REMOVEFILTERS ( dim_country ) )
)
```

`REMOVEFILTERS` on the specific dimensions rather than `ALL ( fact_sales )`, so
the denominator still respects the date slicer. A share-of-total that ignores
the selected period is meaningless.

```dax
Product Revenue Rank =
IF (
    NOT ISBLANK ( [Net Revenue] ),
    RANKX ( ALLSELECTED ( dim_product[description] ), [Net Revenue], , DESC, DENSE )
)
```

`ALLSELECTED` respects slicers but ignores the visual's own row filter, which is
what makes the rank meaningful inside a table. The `IF` suppresses a rank on
rows with no revenue.

```dax
Running Total Revenue =
CALCULATE (
    [Net Revenue],
    FILTER ( ALLSELECTED ( dim_date[full_date] ), dim_date[full_date] <= MAX ( dim_date[full_date] ) )
)
```

---

## 7. Card formatting helpers

```dax
KPI Revenue Label =
VAR V = [Net Revenue]
RETURN
    SWITCH (
        TRUE (),
        ABS ( V ) >= 1e6, FORMAT ( V / 1e6, "£0.00" ) & "M",
        ABS ( V ) >= 1e3, FORMAT ( V / 1e3, "£0.0" ) & "K",
        FORMAT ( V, "£0" )
    )
```

```dax
YoY Indicator =
VAR Pct = [Revenue YoY %]
RETURN
    IF (
        ISBLANK ( Pct ),
        "—",
        IF ( Pct >= 0, "▲ ", "▼ " ) & FORMAT ( ABS ( Pct ), "0.0%" ) & " vs LY"
    )
```

```dax
YoY Colour =
VAR Pct = [Revenue YoY %]
RETURN
    SWITCH (
        TRUE (),
        ISBLANK ( Pct ), "#8A8F98",
        Pct >= 0,        "#1F9D6B",
        "#D0454C"
    )
```

Wired to the card's conditional formatting via **Format → Callout value →
fx → Field value**. Hard-coded hexes rather than theme references because the
report theme is a JSON file, and a measure cannot read from it.

---

## 8. Cross-checking against SQL

Several measures deliberately mirror a SQL view. That redundancy is the test:
`docs/validation.md` records each pair and the query that compares them. A
mismatch means the DAX filter context is wrong — the failure mode that produces
a dashboard which looks fine and reports the wrong number.

| DAX measure | SQL reference |
|---|---|
| `[Net Revenue]` | `analytics.vw_kpi_summary.net_revenue` |
| `[Total Orders]` | `analytics.vw_kpi_summary.total_orders` |
| `[Return Rate %]` | `analytics.vw_kpi_summary.return_rate_pct` |
| `[Revenue YoY %]` (monthly grain) | `analytics.vw_monthly_sales.yoy_growth_pct` |
| `[Revenue 3M Moving Avg]` | `analytics.vw_monthly_sales.revenue_3mo_moving_avg` |
| `[Revenue 7D Moving Avg]` | `analytics.vw_daily_sales.revenue_7d_moving_avg` |
| `[New Customers]` | `analytics.vw_monthly_sales.new_customers` |
