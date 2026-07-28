-- ============================================================================
-- 06_analysis_views.sql   -- the analytics presentation layer
-- Run against retail_analytics, after 05_indexes.sql.
--
-- Power BI connects to this schema and nothing else. core stays private, so
-- the fact and dimensions can be reshaped without breaking the report as long
-- as these signatures hold.
--
-- Two kinds of object live here:
--
--   vw_dim_* / vw_fact_sales   thin pass-throughs. These are what the report's
--                              star schema imports.
--
--   everything else            pre-aggregated analysis. Some of it duplicates a
--                              DAX measure on purpose -- see the note on
--                              vw_monthly_sales.
-- ============================================================================

-- ============================================================================
-- PASS-THROUGH VIEWS -- the report's model
-- ============================================================================

CREATE OR REPLACE VIEW analytics.vw_dim_date AS
SELECT date_key, full_date, year, quarter, quarter_name, year_quarter,
       month, month_name, month_short, year_month, month_start, month_end,
       day_of_month, day_of_week, day_name, day_short,
       week_of_year, day_of_year, is_weekend, is_complete_month
FROM core.dim_date;

CREATE OR REPLACE VIEW analytics.vw_dim_product AS
SELECT product_key, stock_code, description, product_category
FROM core.dim_product
WHERE NOT is_service_line;          -- service lines never reach the fact

CREATE OR REPLACE VIEW analytics.vw_dim_customer AS
SELECT c.customer_key, c.customer_id, c.customer_label,
       c.is_known_customer,
       co.country_clean AS country, co.region
FROM core.dim_customer c
LEFT JOIN core.dim_country co ON co.country_key = c.country_key;

CREATE OR REPLACE VIEW analytics.vw_dim_country AS
SELECT country_key, country_clean AS country, iso2, region, is_domestic
FROM core.dim_country;

CREATE OR REPLACE VIEW analytics.vw_fact_sales AS
SELECT sale_key, invoice_no, invoice_line, date_key, invoice_ts,
       product_key, customer_key, country_key,
       quantity, unit_price, line_revenue, is_return, is_first_order
FROM core.fact_sales;


-- ============================================================================
-- KPI SUMMARY -- one row, the headline numbers
-- Useful as a sanity check that the DAX cards agree with the database.
-- ============================================================================

-- total_orders counts sales invoices only. Return invoices (the 'C...' series)
-- are counted separately as return_invoices. Mixing them would inflate the
-- denominator of average order value and understate it. The DAX measure
-- [Total Orders] applies the identical filter so the two agree exactly.
CREATE OR REPLACE VIEW analytics.vw_kpi_summary AS
SELECT
    ROUND(SUM(f.line_revenue), 2)                              AS net_revenue,
    COUNT(DISTINCT f.invoice_no) FILTER (WHERE NOT f.is_return) AS total_orders,
    COUNT(DISTINCT f.invoice_no) FILTER (WHERE f.is_return)    AS return_invoices,
    COUNT(DISTINCT f.customer_key) FILTER (WHERE f.customer_key <> -1)
                                                               AS active_customers,
    COUNT(DISTINCT f.product_key)                              AS products_sold,
    SUM(f.quantity)                                            AS net_units,
    ROUND(SUM(f.line_revenue)
          / NULLIF(COUNT(DISTINCT f.invoice_no)
                   FILTER (WHERE NOT f.is_return), 0), 2)      AS avg_order_value,
    ROUND(
        ABS(SUM(f.line_revenue) FILTER (WHERE f.is_return))
        / NULLIF(SUM(f.line_revenue) FILTER (WHERE NOT f.is_return), 0) * 100, 2
    )                                                          AS return_rate_pct,
    MIN(f.invoice_ts)::date                                    AS first_sale_date,
    MAX(f.invoice_ts)::date                                    AS last_sale_date
FROM core.fact_sales f;


-- ============================================================================
-- MONTHLY SALES -- trend, MoM, YoY and a 3-month moving average
--
-- These same numbers are computed again as DAX measures in the report. That
-- duplication is intentional and is the point of docs/validation.md: the SQL
-- here is the reference implementation, and the DAX is checked against it. A
-- YoY measure that disagrees with the warehouse is the single most common way
-- a Power BI dashboard ships quietly wrong.
--
-- LAG(..., 12) is safe only because the month series is dense -- every month
-- between the first and last sale has a row. Verified in 07_data_quality.sql.
-- ============================================================================

CREATE OR REPLACE VIEW analytics.vw_monthly_sales AS
WITH monthly AS (
    SELECT
        d.year_month,
        d.month_start,
        d.year,
        d.month,
        ROUND(SUM(f.line_revenue), 2)               AS net_revenue,
        COUNT(DISTINCT f.invoice_no)
            FILTER (WHERE NOT f.is_return)          AS orders,
        COUNT(DISTINCT f.customer_key)
            FILTER (WHERE f.customer_key <> -1)     AS active_customers,
        COUNT(DISTINCT f.customer_key)
            FILTER (WHERE f.customer_key <> -1 AND f.is_first_order)
                                                    AS new_customers,
        SUM(f.quantity)                             AS net_units
    FROM core.fact_sales f
    JOIN core.dim_date d ON d.date_key = f.date_key
    GROUP BY d.year_month, d.month_start, d.year, d.month
)
SELECT
    m.year_month,
    m.month_start,
    m.year,
    m.month,
    m.net_revenue,
    m.orders,
    m.active_customers,
    m.new_customers,
    m.active_customers - m.new_customers                      AS returning_customers,
    m.net_units,
    ROUND(m.net_revenue / NULLIF(m.orders, 0), 2)            AS avg_order_value,

    LAG(m.net_revenue, 1) OVER w                              AS prev_month_revenue,
    ROUND(
        (m.net_revenue - LAG(m.net_revenue, 1) OVER w)
        / NULLIF(ABS(LAG(m.net_revenue, 1) OVER w), 0) * 100, 2
    )                                                         AS mom_growth_pct,

    LAG(m.net_revenue, 12) OVER w                             AS prev_year_revenue,
    ROUND(
        (m.net_revenue - LAG(m.net_revenue, 12) OVER w)
        / NULLIF(ABS(LAG(m.net_revenue, 12) OVER w), 0) * 100, 2
    )                                                         AS yoy_growth_pct,

    ROUND(AVG(m.net_revenue) OVER (
        ORDER BY m.month_start ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ), 2)                                                     AS revenue_3mo_moving_avg,

    ROUND(SUM(m.net_revenue) OVER (
        PARTITION BY m.year ORDER BY m.month_start
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ), 2)                                                     AS revenue_ytd
FROM monthly m
WINDOW w AS (ORDER BY m.month_start);


-- ============================================================================
-- DAILY SALES -- 7-day and 30-day moving averages
--
-- Retail daily revenue is dominated by day-of-week effects; a 7-day window is
-- the shortest one that removes them cleanly. Days with no trading appear with
-- zero revenue rather than being skipped, otherwise the moving average would
-- average over an inconsistent number of calendar days.
-- ============================================================================

CREATE OR REPLACE VIEW analytics.vw_daily_sales AS
WITH bounds AS (
    SELECT MIN(invoice_ts)::date AS from_date, MAX(invoice_ts)::date AS to_date
    FROM core.fact_sales
),
daily AS (
    SELECT
        d.full_date,
        d.day_short,
        d.is_weekend,
        COALESCE(ROUND(SUM(f.line_revenue), 2), 0) AS net_revenue,
        COUNT(DISTINCT f.invoice_no)               AS orders
    FROM core.dim_date d
    CROSS JOIN bounds b
    LEFT JOIN core.fact_sales f ON f.date_key = d.date_key
    WHERE d.full_date BETWEEN b.from_date AND b.to_date
    GROUP BY d.full_date, d.day_short, d.is_weekend
)
SELECT
    full_date,
    day_short,
    is_weekend,
    net_revenue,
    orders,
    ROUND(AVG(net_revenue) OVER (
        ORDER BY full_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ), 2) AS revenue_7d_moving_avg,
    ROUND(AVG(net_revenue) OVER (
        ORDER BY full_date ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ), 2) AS revenue_30d_moving_avg
FROM daily;


-- ============================================================================
-- PRODUCT PERFORMANCE -- ranking plus ABC (Pareto) classification
--
-- ABC bands follow the usual inventory convention on cumulative revenue share:
--   A  top 80%   B  next 15%   C  final 5%
-- The band is assigned on the row that crosses each threshold, so the SKU that
-- takes cumulative share past 80% is itself still an A.
-- ============================================================================

CREATE OR REPLACE VIEW analytics.vw_product_performance AS
WITH product_totals AS (
    SELECT
        p.product_key,
        p.stock_code,
        p.description,
        p.product_category,
        ROUND(SUM(f.line_revenue), 2)                          AS net_revenue,
        SUM(f.quantity)                                        AS net_units,
        COUNT(DISTINCT f.invoice_no)                           AS orders,
        COUNT(DISTINCT f.customer_key)
            FILTER (WHERE f.customer_key <> -1)                AS distinct_customers,
        ROUND(AVG(f.unit_price), 4)                            AS avg_unit_price,
        ROUND(
            ABS(SUM(f.line_revenue) FILTER (WHERE f.is_return))
            / NULLIF(SUM(f.line_revenue) FILTER (WHERE NOT f.is_return), 0) * 100, 2
        )                                                      AS return_rate_pct
    FROM core.fact_sales f
    JOIN core.dim_product p ON p.product_key = f.product_key
    GROUP BY p.product_key, p.stock_code, p.description, p.product_category
),
ranked AS (
    SELECT
        pt.*,
        RANK() OVER (ORDER BY pt.net_revenue DESC)             AS revenue_rank,
        RANK() OVER (
            PARTITION BY pt.product_category ORDER BY pt.net_revenue DESC
        )                                                      AS rank_in_category,
        SUM(pt.net_revenue) OVER (ORDER BY pt.net_revenue DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)  AS cumulative_revenue,
        SUM(pt.net_revenue) OVER ()                            AS total_revenue
    FROM product_totals pt
)
SELECT
    product_key, stock_code, description, product_category,
    net_revenue, net_units, orders, distinct_customers,
    avg_unit_price, return_rate_pct,
    revenue_rank, rank_in_category,
    ROUND(net_revenue / NULLIF(total_revenue, 0) * 100, 4)        AS revenue_share_pct,
    ROUND(cumulative_revenue / NULLIF(total_revenue, 0) * 100, 2) AS cumulative_share_pct,
    CASE
        WHEN (cumulative_revenue - net_revenue) / NULLIF(total_revenue, 0) < 0.80 THEN 'A'
        WHEN (cumulative_revenue - net_revenue) / NULLIF(total_revenue, 0) < 0.95 THEN 'B'
        ELSE 'C'
    END                                                           AS abc_class
FROM ranked;


-- ============================================================================
-- COUNTRY PERFORMANCE
-- ============================================================================

CREATE OR REPLACE VIEW analytics.vw_country_performance AS
SELECT
    co.country_key,
    co.country_clean AS country,
    co.iso2,
    co.region,
    co.is_domestic,
    ROUND(SUM(f.line_revenue), 2)                          AS net_revenue,
    COUNT(DISTINCT f.invoice_no)                           AS orders,
    COUNT(DISTINCT f.customer_key)
        FILTER (WHERE f.customer_key <> -1)                AS active_customers,
    SUM(f.quantity)                                        AS net_units,
    ROUND(SUM(f.line_revenue)
          / NULLIF(COUNT(DISTINCT f.invoice_no), 0), 2)    AS avg_order_value,
    ROUND(SUM(f.line_revenue)
          / NULLIF(SUM(SUM(f.line_revenue)) OVER (), 0) * 100, 2)
                                                           AS revenue_share_pct,
    RANK() OVER (ORDER BY SUM(f.line_revenue) DESC)        AS revenue_rank
FROM core.fact_sales f
JOIN core.dim_country co ON co.country_key = f.country_key
GROUP BY co.country_key, co.country_clean, co.iso2, co.region, co.is_domestic;


-- ============================================================================
-- CUSTOMER RFM -- Recency, Frequency, Monetary
--
-- Recency is measured against the last transaction in the dataset, NOT against
-- CURRENT_DATE. This is a static historical extract that ends in December 2011;
-- scoring against today would make every customer maximally stale and collapse
-- the segmentation to a single bucket.
--
-- Guests (customer_key = -1) are excluded -- they cannot be scored across time.
-- ============================================================================

CREATE OR REPLACE VIEW analytics.vw_customer_rfm AS
WITH snapshot AS (
    SELECT MAX(invoice_ts)::date AS as_of_date FROM core.fact_sales
),
customer_totals AS (
    SELECT
        f.customer_key,
        MAX(f.invoice_ts)::date                     AS last_order_date,
        MIN(f.invoice_ts)::date                     AS first_order_date,
        (SELECT as_of_date FROM snapshot) - MAX(f.invoice_ts)::date AS recency_days,
        COUNT(DISTINCT f.invoice_no)                AS frequency_orders,
        ROUND(SUM(f.line_revenue), 2)               AS monetary_revenue,
        ROUND(SUM(f.line_revenue)
              / NULLIF(COUNT(DISTINCT f.invoice_no), 0), 2) AS avg_order_value,
        MAX(f.invoice_ts)::date - MIN(f.invoice_ts)::date   AS tenure_days
    FROM core.fact_sales f
    WHERE f.customer_key <> -1
    GROUP BY f.customer_key
    HAVING SUM(f.line_revenue) > 0        -- net-negative accounts cannot be scored
),
scored AS (
    SELECT
        ct.*,
        -- Recency inverted: fewer days since last order is a better score.
        NTILE(5) OVER (ORDER BY ct.recency_days DESC)      AS r_score,
        NTILE(5) OVER (ORDER BY ct.frequency_orders ASC)   AS f_score,
        NTILE(5) OVER (ORDER BY ct.monetary_revenue ASC)   AS m_score
    FROM customer_totals ct
)
SELECT
    s.customer_key,
    c.customer_id,
    c.customer_label,
    co.country_clean AS country,
    co.region,
    s.first_order_date,
    s.last_order_date,
    s.tenure_days,
    s.recency_days,
    s.frequency_orders,
    s.monetary_revenue,
    s.avg_order_value,
    s.r_score, s.f_score, s.m_score,
    s.r_score::text || s.f_score::text || s.m_score::text AS rfm_cell,
    CASE
        WHEN s.r_score >= 4 AND s.f_score >= 4 AND s.m_score >= 4 THEN 'Champions'
        WHEN s.r_score >= 3 AND s.f_score >= 3                    THEN 'Loyal'
        WHEN s.r_score >= 4 AND s.f_score <= 2                    THEN 'New / Promising'
        WHEN s.r_score = 3  AND s.f_score <= 2                    THEN 'Needs Attention'
        WHEN s.r_score <= 2 AND s.f_score >= 4 AND s.m_score >= 4 THEN 'At Risk - High Value'
        WHEN s.r_score <= 2 AND s.f_score >= 3                    THEN 'At Risk'
        WHEN s.r_score = 1                                        THEN 'Lost'
        ELSE 'Hibernating'
    END AS rfm_segment
FROM scored s
JOIN      core.dim_customer c  ON c.customer_key = s.customer_key
LEFT JOIN core.dim_country  co ON co.country_key = c.country_key;


-- ============================================================================
-- COHORT RETENTION -- customers grouped by their first-purchase month
--
-- Feeds a triangular heatmap in the report. months_since = 0 is the acquisition
-- month, so retention_pct is 100% there by construction.
-- ============================================================================

CREATE OR REPLACE VIEW analytics.vw_cohort_retention AS
WITH first_purchase AS (
    SELECT
        f.customer_key,
        to_char(MIN(f.invoice_ts), 'YYYY-MM')       AS cohort_month,
        date_trunc('month', MIN(f.invoice_ts))::date AS cohort_month_start
    FROM core.fact_sales f
    WHERE f.customer_key <> -1
    GROUP BY f.customer_key
),
activity AS (
    SELECT DISTINCT
        f.customer_key,
        fp.cohort_month,
        fp.cohort_month_start,
        date_trunc('month', f.invoice_ts)::date AS activity_month_start
    FROM core.fact_sales f
    JOIN first_purchase fp ON fp.customer_key = f.customer_key
    WHERE f.customer_key <> -1
),
cohort_sizes AS (
    SELECT cohort_month, COUNT(*) AS cohort_size
    FROM first_purchase
    GROUP BY cohort_month
)
SELECT
    a.cohort_month,
    a.cohort_month_start,
    to_char(a.activity_month_start, 'YYYY-MM') AS activity_month,
    (EXTRACT(YEAR  FROM a.activity_month_start) - EXTRACT(YEAR  FROM a.cohort_month_start)) * 12
  + (EXTRACT(MONTH FROM a.activity_month_start) - EXTRACT(MONTH FROM a.cohort_month_start))
                                               AS months_since,
    cs.cohort_size,
    COUNT(DISTINCT a.customer_key)             AS active_customers,
    ROUND(COUNT(DISTINCT a.customer_key)::numeric
          / NULLIF(cs.cohort_size, 0) * 100, 2) AS retention_pct
FROM activity a
JOIN cohort_sizes cs ON cs.cohort_month = a.cohort_month
GROUP BY a.cohort_month, a.cohort_month_start, a.activity_month_start, cs.cohort_size;


-- ============================================================================
-- RETURNS -- monthly return rate by category
-- ============================================================================

CREATE OR REPLACE VIEW analytics.vw_returns_analysis AS
SELECT
    d.year_month,
    d.month_start,
    p.product_category,
    ROUND(SUM(f.line_revenue) FILTER (WHERE NOT f.is_return), 2) AS gross_revenue,
    ROUND(ABS(SUM(f.line_revenue) FILTER (WHERE f.is_return)), 2) AS returned_revenue,
    ROUND(SUM(f.line_revenue), 2)                                 AS net_revenue,
    COUNT(DISTINCT f.invoice_no) FILTER (WHERE f.is_return)       AS return_invoices,
    ROUND(
        ABS(SUM(f.line_revenue) FILTER (WHERE f.is_return))
        / NULLIF(SUM(f.line_revenue) FILTER (WHERE NOT f.is_return), 0) * 100, 2
    )                                                             AS return_rate_pct
FROM core.fact_sales f
JOIN core.dim_date    d ON d.date_key    = f.date_key
JOIN core.dim_product p ON p.product_key = f.product_key
GROUP BY d.year_month, d.month_start, p.product_category;


\echo 'Analytics views created.'
