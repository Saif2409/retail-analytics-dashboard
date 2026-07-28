-- ============================================================================
-- 05_indexes.sql   -- indexes + planner statistics
-- Run against retail_analytics, after 04_transform_facts.sql.
--
-- Power BI's Import mode issues one large sequential read per table at refresh,
-- which no index helps. These exist for the interactive work that surrounds
-- that: the analysis views in 06, the assertions in 07, and any ad-hoc
-- DirectQuery drill-through, all of which filter or group on the foreign keys.
-- ============================================================================

CREATE INDEX IF NOT EXISTS ix_fact_sales_date_key
    ON core.fact_sales (date_key);

CREATE INDEX IF NOT EXISTS ix_fact_sales_product_key
    ON core.fact_sales (product_key);

CREATE INDEX IF NOT EXISTS ix_fact_sales_customer_key
    ON core.fact_sales (customer_key);

CREATE INDEX IF NOT EXISTS ix_fact_sales_country_key
    ON core.fact_sales (country_key);

-- Invoice-level rollups (order counts, basket size) group by this constantly.
CREATE INDEX IF NOT EXISTS ix_fact_sales_invoice_no
    ON core.fact_sales (invoice_no);

-- Returns are a small slice of the table, so a partial index stays tiny while
-- still covering every return-rate query.
CREATE INDEX IF NOT EXISTS ix_fact_sales_returns
    ON core.fact_sales (date_key)
    WHERE is_return;

CREATE INDEX IF NOT EXISTS ix_dim_date_full_date
    ON core.dim_date (full_date);

ANALYZE core.fact_sales;
ANALYZE core.dim_date;
ANALYZE core.dim_product;
ANALYZE core.dim_customer;
ANALYZE core.dim_country;

\echo 'Indexes built and statistics refreshed.'
