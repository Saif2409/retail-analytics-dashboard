-- ============================================================================
-- 07_data_quality.sql   -- assertions over the built warehouse
-- Run against retail_analytics, last in the pipeline.
--
-- Creates analytics.vw_data_quality (re-runnable, one row per check) and then
-- raises an exception if anything failed, so the pipeline stops loudly instead
-- of publishing a dashboard built on broken numbers.
--
--   SELECT * FROM analytics.vw_data_quality ORDER BY status DESC, check_name;
-- ============================================================================

CREATE OR REPLACE VIEW analytics.vw_data_quality AS

-- 1. Reconciliation. The whole point of core.fact_sales_exclusions: every
--    staging row is either in the fact or accounted for by a named reason.
SELECT
    'reconciliation: staging = fact + exclusions'          AS check_name,
    CASE WHEN (SELECT COUNT(*) FROM staging.online_retail_raw)
            = (SELECT COUNT(*) FROM core.fact_sales)
            + (SELECT COALESCE(SUM(rows_excluded), 0) FROM core.fact_sales_exclusions)
         THEN 'PASS' ELSE 'FAIL' END                       AS status,
    format('staging=%s fact=%s excluded=%s',
        (SELECT COUNT(*) FROM staging.online_retail_raw),
        (SELECT COUNT(*) FROM core.fact_sales),
        (SELECT COALESCE(SUM(rows_excluded), 0) FROM core.fact_sales_exclusions)
    )                                                      AS detail

UNION ALL

-- 2. The sheet overlap actually got collapsed. If de-duplication silently
--    failed, December 2010 would carry two copies of nine trading days and
--    every 2011 YoY figure would be wrong.
SELECT
    'no duplicate invoice lines in fact',
    CASE WHEN NOT EXISTS (
        SELECT 1 FROM core.fact_sales
        GROUP BY invoice_no, product_key, invoice_ts, quantity, unit_price
        HAVING COUNT(*) > 1
    ) THEN 'PASS' ELSE 'FAIL' END,
    format('%s natural keys appear more than once', (
        SELECT COUNT(*) FROM (
            SELECT 1 FROM core.fact_sales
            GROUP BY invoice_no, product_key, invoice_ts, quantity, unit_price
            HAVING COUNT(*) > 1
        ) x
    ))

UNION ALL

-- 3. dim_date must have no gaps or Power BI time intelligence returns blanks.
SELECT
    'dim_date is contiguous',
    CASE WHEN (SELECT COUNT(*) FROM core.dim_date)
            = (SELECT MAX(full_date) - MIN(full_date) + 1 FROM core.dim_date)
         THEN 'PASS' ELSE 'FAIL' END,
    format('%s rows spanning %s..%s',
        (SELECT COUNT(*) FROM core.dim_date),
        (SELECT MIN(full_date) FROM core.dim_date),
        (SELECT MAX(full_date) FROM core.dim_date))

UNION ALL

-- 4. Dense month series. vw_monthly_sales uses LAG(revenue, 12) for YoY, which
--    is only equivalent to "same month last year" when no month is missing.
SELECT
    'monthly series is dense (LAG 12 = same month last year)',
    CASE WHEN (SELECT COUNT(DISTINCT date_trunc('month', invoice_ts)) FROM core.fact_sales)
            = (SELECT (EXTRACT(YEAR  FROM MAX(invoice_ts)) - EXTRACT(YEAR  FROM MIN(invoice_ts))) * 12
                    + (EXTRACT(MONTH FROM MAX(invoice_ts)) - EXTRACT(MONTH FROM MIN(invoice_ts))) + 1
               FROM core.fact_sales)
         THEN 'PASS' ELSE 'FAIL' END,
    format('%s distinct trading months', (
        SELECT COUNT(DISTINCT date_trunc('month', invoice_ts)) FROM core.fact_sales))

UNION ALL

-- 5. Derived measure integrity.
SELECT
    'line_revenue = quantity * unit_price',
    CASE WHEN NOT EXISTS (
        SELECT 1 FROM core.fact_sales
        WHERE ABS(line_revenue - ROUND(quantity * unit_price, 4)) > 0.0001
    ) THEN 'PASS' ELSE 'FAIL' END,
    format('%s mismatched rows', (
        SELECT COUNT(*) FROM core.fact_sales
        WHERE ABS(line_revenue - ROUND(quantity * unit_price, 4)) > 0.0001))

UNION ALL

-- 6. No service lines leaked into the fact.
SELECT
    'fact contains no service lines',
    CASE WHEN NOT EXISTS (
        SELECT 1 FROM core.fact_sales f
        JOIN core.dim_product p ON p.product_key = f.product_key
        WHERE p.is_service_line
    ) THEN 'PASS' ELSE 'FAIL' END,
    'postage / discounts / bank charges / test rows excluded upstream'

UNION ALL

-- 7. Guest revenue is attributed, not dropped.
SELECT
    'guest member (-1) exists and carries revenue',
    CASE WHEN EXISTS (SELECT 1 FROM core.dim_customer WHERE customer_key = -1)
          AND EXISTS (SELECT 1 FROM core.fact_sales   WHERE customer_key = -1)
         THEN 'PASS' ELSE 'FAIL' END,
    format('%s guest rows, %s net revenue',
        (SELECT COUNT(*) FROM core.fact_sales WHERE customer_key = -1),
        (SELECT ROUND(COALESCE(SUM(line_revenue), 0), 2)
         FROM core.fact_sales WHERE customer_key = -1))

UNION ALL

-- 8. Nothing NULL where the model promises a value.
SELECT
    'no NULLs in fact measures or keys',
    CASE WHEN NOT EXISTS (
        SELECT 1 FROM core.fact_sales
        WHERE line_revenue IS NULL OR quantity IS NULL OR unit_price IS NULL
           OR date_key IS NULL OR product_key IS NULL
           OR customer_key IS NULL OR country_key IS NULL
    ) THEN 'PASS' ELSE 'FAIL' END,
    'enforced by NOT NULL, re-checked here'

UNION ALL

-- 9. Return rate in a plausible band. A rate outside this range almost always
--    means returns were double-counted or the sign convention flipped.
SELECT
    'return rate is plausible (0-25%)',
    CASE WHEN (SELECT ABS(SUM(line_revenue) FILTER (WHERE is_return))
                    / NULLIF(SUM(line_revenue) FILTER (WHERE NOT is_return), 0) * 100
               FROM core.fact_sales) BETWEEN 0 AND 25
         THEN 'PASS' ELSE 'FAIL' END,
    format('%s%%', (
        SELECT ROUND(ABS(SUM(line_revenue) FILTER (WHERE is_return))
                   / NULLIF(SUM(line_revenue) FILTER (WHERE NOT is_return), 0) * 100, 2)
        FROM core.fact_sales))

UNION ALL

-- 10. Every fact row resolves to a real dimension member.
SELECT
    'no orphan dimension keys',
    CASE WHEN NOT EXISTS (
        SELECT 1 FROM core.fact_sales f
        LEFT JOIN core.dim_date     d  ON d.date_key     = f.date_key
        LEFT JOIN core.dim_product  p  ON p.product_key  = f.product_key
        LEFT JOIN core.dim_customer c  ON c.customer_key = f.customer_key
        LEFT JOIN core.dim_country  co ON co.country_key = f.country_key
        WHERE d.date_key IS NULL OR p.product_key IS NULL
           OR c.customer_key IS NULL OR co.country_key IS NULL
    ) THEN 'PASS' ELSE 'FAIL' END,
    'foreign keys enforce this; asserted anyway'

UNION ALL

-- 11. The two years needed for YoY are both present and reasonably complete.
SELECT
    'at least two calendar years of sales',
    CASE WHEN (SELECT COUNT(DISTINCT EXTRACT(YEAR FROM invoice_ts)) FROM core.fact_sales) >= 2
         THEN 'PASS' ELSE 'FAIL' END,
    format('years present: %s', (
        SELECT string_agg(DISTINCT EXTRACT(YEAR FROM invoice_ts)::text, ', ' ORDER BY EXTRACT(YEAR FROM invoice_ts)::text)
        FROM core.fact_sales));


-- ----------------------------------------------------------------------------
-- Fail the run if any check failed.
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    failed_checks text;
    failed_count  int;
BEGIN
    SELECT COUNT(*), string_agg(check_name || ' -> ' || detail, E'\n  ')
      INTO failed_count, failed_checks
      FROM analytics.vw_data_quality
     WHERE status = 'FAIL';

    IF failed_count > 0 THEN
        RAISE EXCEPTION E'% data quality check(s) FAILED:\n  %', failed_count, failed_checks;
    END IF;

    RAISE NOTICE 'All data quality checks passed.';
END $$;
