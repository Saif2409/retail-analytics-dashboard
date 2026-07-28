-- ============================================================================
-- 01_schema.sql   -- schemas + landing table
-- Run against retail_analytics.
--
-- Three schemas, one per stage, so it is always obvious which layer a
-- given object belongs to:
--   staging    verbatim copy of the source file, no rules applied
--   core       cleaned star schema (dimensions + fact)
--   analytics  the read-only surface Power BI connects to
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS analytics;

COMMENT ON SCHEMA staging   IS 'Raw landing zone. Mirrors the source CSV exactly; no cleaning.';
COMMENT ON SCHEMA core      IS 'Cleaned star schema: conformed dimensions and the sales fact.';
COMMENT ON SCHEMA analytics IS 'Presentation layer consumed by Power BI. Views only.';

-- ----------------------------------------------------------------------------
-- Landing table
--
-- Every column is deliberately permissive (TEXT where the source is dirty, no
-- NOT NULL, no keys). Loading must never fail on a data problem -- problems are
-- found and reported by sql/07_data_quality.sql, not by a failed COPY.
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS staging.online_retail_raw;

CREATE TABLE staging.online_retail_raw (
    invoice_no    text,
    stock_code    text,
    description   text,
    quantity      integer,
    invoice_ts    timestamp,
    unit_price    numeric(12, 4),
    customer_id   integer,
    country       text,
    source_sheet  text
);

COMMENT ON TABLE staging.online_retail_raw IS
    'Raw Online Retail II rows. source_sheet preserves which workbook tab a row '
    'came from, which is what makes the 2010-12-01..2010-12-09 overlap between '
    'the two tabs detectable and provable in 07_data_quality.sql.';

COMMENT ON COLUMN staging.online_retail_raw.invoice_no IS
    'Invoice number. A leading "C" marks a cancellation/return.';
COMMENT ON COLUMN staging.online_retail_raw.stock_code IS
    'Product code. Real products match ^[0-9]{5}; other values are service '
    'lines (postage, manual adjustments, bank charges, samples, test rows).';
COMMENT ON COLUMN staging.online_retail_raw.customer_id IS
    'NULL for guest checkouts -- roughly a fifth of all rows.';
