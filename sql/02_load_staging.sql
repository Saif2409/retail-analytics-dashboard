-- ============================================================================
-- 02_load_staging.sql   -- bulk load the CSV into the landing table
-- Run against retail_analytics, after 01_schema.sql, FROM THE REPO ROOT:
--
--   psql -d retail_analytics -f sql/02_load_staging.sql
--
-- \copy rather than COPY: \copy streams from the *client*, so it needs no
-- superuser file-read privilege and no server-side access to the path -- which
-- matters on Windows, where the postgres service account usually cannot read
-- anything under C:\Users. It is also an order of magnitude faster than
-- row-by-row INSERTs from Python; a million rows lands in a few seconds.
--
-- The path below is relative and hard-coded on purpose. psql does not perform
-- variable interpolation inside \copy -- the whole remainder of the line is
-- taken literally, so ':csv_path' would be read as a filename called
-- ":csv_path". \copy resolves relative paths against psql's own working
-- directory, hence the requirement to run from the repo root.
-- etl/run_pipeline.ps1 handles that for you.
-- ============================================================================

TRUNCATE staging.online_retail_raw;

\copy staging.online_retail_raw (invoice_no, stock_code, description, quantity, invoice_ts, unit_price, customer_id, country, source_sheet) FROM 'data/processed/online_retail_II.csv' WITH (FORMAT csv, HEADER true, NULL '')

ANALYZE staging.online_retail_raw;

\echo ''
\echo 'Staging load complete:'

SELECT
    source_sheet,
    COUNT(*)                                AS rows_loaded,
    MIN(invoice_ts)::date                   AS from_date,
    MAX(invoice_ts)::date                   AS to_date,
    COUNT(*) FILTER (WHERE customer_id IS NULL) AS missing_customer_id
FROM staging.online_retail_raw
GROUP BY source_sheet
ORDER BY source_sheet;
