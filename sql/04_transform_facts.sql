-- ============================================================================
-- 04_transform_facts.sql   -- build core.fact_sales
-- Run against retail_analytics, after 03_transform_dimensions.sql.
--
-- Every row dropped between staging and fact is dropped by exactly one rule
-- below, and each rule is counted in core.fact_sales_exclusions so the row
-- count always reconciles. sql/07_data_quality.sql asserts that it does.
--
-- Grain: one row per invoice line.
-- ============================================================================

BEGIN;

DROP TABLE IF EXISTS core.fact_sales            CASCADE;
DROP TABLE IF EXISTS core.fact_sales_exclusions CASCADE;


-- ----------------------------------------------------------------------------
-- Step 1 -- de-duplicate.
--
-- Two distinct sources of duplication:
--
--   a) Sheet overlap. 'Year 2009-2010' runs to 2010-12-09 and 'Year 2010-2011'
--      starts at 2010-12-01, so nine days are present twice. Loading both tabs
--      naively inflates December 2010 by roughly a full extra week -- which
--      would then corrupt every YoY comparison against December 2011.
--
--   b) Exact repeated lines inside a single sheet, a known artefact of the
--      original extract.
--
-- Both are handled by the same natural key. Where a row exists in both tabs the
-- earlier tab wins, purely so the choice is deterministic.
--
-- Caveat, stated plainly: a genuine invoice that legitimately lists the same
-- SKU twice at the same price in the same second is indistinguishable from an
-- artefact and is collapsed too. That is the accepted trade-off -- the
-- alternative is knowingly double-counting the December 2010 overlap.
-- ----------------------------------------------------------------------------

CREATE TEMP TABLE deduped ON COMMIT DROP AS
SELECT DISTINCT ON (
        upper(trim(invoice_no)), upper(trim(stock_code)),
        invoice_ts, quantity, unit_price, customer_id
    )
    upper(trim(invoice_no)) AS invoice_no,
    upper(trim(stock_code)) AS stock_code,
    invoice_ts,
    quantity,
    unit_price,
    customer_id,
    country,
    source_sheet
FROM staging.online_retail_raw
ORDER BY
    upper(trim(invoice_no)), upper(trim(stock_code)),
    invoice_ts, quantity, unit_price, customer_id,
    source_sheet;                       -- '2009-2010' sorts before '2010-2011'


-- ----------------------------------------------------------------------------
-- Step 2 -- classify every deduplicated row as loadable or excluded.
-- ----------------------------------------------------------------------------

CREATE TEMP TABLE classified ON COMMIT DROP AS
SELECT
    d.*,
    CASE
        WHEN d.invoice_ts IS NULL OR d.stock_code IS NULL OR d.invoice_no IS NULL
            THEN 'missing_key_field'
        WHEN p.is_service_line
            THEN 'service_line'          -- postage, discounts, bank charges, tests
        WHEN d.unit_price IS NULL OR d.unit_price <= 0
            THEN 'non_positive_price'    -- freebies and bad-debt write-offs
        WHEN d.quantity IS NULL OR d.quantity = 0
            THEN 'zero_quantity'
        ELSE NULL                        -- NULL == keep
    END AS exclusion_reason
FROM deduped d
LEFT JOIN core.dim_product p ON p.stock_code = d.stock_code;


-- ----------------------------------------------------------------------------
-- Step 3 -- the fact.
--
-- Returns are KEPT, flagged with is_return and left with their negative
-- quantity. Net revenue is the honest headline: stripping returns out would
-- overstate every KPI on the dashboard by the return rate.
-- ----------------------------------------------------------------------------

CREATE TABLE core.fact_sales (
    sale_key      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invoice_no    text     NOT NULL,
    invoice_line  smallint NOT NULL,
    date_key      integer  NOT NULL REFERENCES core.dim_date     (date_key),
    invoice_ts    timestamp NOT NULL,
    product_key   integer  NOT NULL REFERENCES core.dim_product  (product_key),
    customer_key  integer  NOT NULL REFERENCES core.dim_customer (customer_key),
    country_key   integer  NOT NULL REFERENCES core.dim_country  (country_key),
    quantity      integer  NOT NULL,
    unit_price    numeric(12, 4) NOT NULL,
    line_revenue  numeric(14, 4) NOT NULL,
    is_return     boolean  NOT NULL,
    is_first_order boolean NOT NULL
);

INSERT INTO core.fact_sales (
    invoice_no, invoice_line, date_key, invoice_ts,
    product_key, customer_key, country_key,
    quantity, unit_price, line_revenue, is_return, is_first_order
)
SELECT
    c.invoice_no,
    ROW_NUMBER() OVER (
        PARTITION BY c.invoice_no
        ORDER BY c.invoice_ts, c.stock_code
    )::smallint,
    (to_char(c.invoice_ts, 'YYYYMMDD'))::int,
    c.invoice_ts,
    p.product_key,
    COALESCE(cu.customer_key, -1),               -- guest member
    co.country_key,
    c.quantity,
    c.unit_price,
    ROUND(c.quantity * c.unit_price, 4),
    c.invoice_no LIKE 'C%' OR c.quantity < 0,
    -- TRUE on every line of the customer's earliest purchase invoice. Computing
    -- this once here keeps the New/Returning split in Power BI to a plain
    -- boolean filter, instead of the usual expensive "minimum invoice date per
    -- customer" DAX pattern that recalculates on every visual.
    --
    -- Window functions run after WHERE, so the partition already sees only
    -- loadable rows. Guests are forced FALSE: PARTITION BY would lump every
    -- NULL customer into one group and invent a shared "first order" for them.
    c.customer_id IS NOT NULL
        AND c.invoice_ts = MIN(c.invoice_ts) OVER (PARTITION BY c.customer_id)
FROM classified c
JOIN      core.dim_product  p  ON p.stock_code   = c.stock_code
JOIN      core.dim_country  co ON co.country_name = c.country
LEFT JOIN core.dim_customer cu ON cu.customer_id = c.customer_id
WHERE c.exclusion_reason IS NULL;


-- ----------------------------------------------------------------------------
-- Step 4 -- the audit trail. Nothing disappears without a counted reason.
-- ----------------------------------------------------------------------------

CREATE TABLE core.fact_sales_exclusions (
    exclusion_reason text    NOT NULL PRIMARY KEY,
    rows_excluded    bigint  NOT NULL,
    revenue_excluded numeric(16, 4) NOT NULL,
    note             text    NOT NULL
);

INSERT INTO core.fact_sales_exclusions
SELECT
    c.exclusion_reason,
    COUNT(*),
    COALESCE(ROUND(SUM(c.quantity * c.unit_price), 4), 0),
    CASE c.exclusion_reason
        WHEN 'service_line'       THEN 'Postage, discounts, bank charges, manual adjustments, test rows'
        WHEN 'non_positive_price' THEN 'Price <= 0: giveaways and bad-debt write-offs'
        WHEN 'zero_quantity'      THEN 'Zero or NULL quantity, no economic value'
        WHEN 'missing_key_field'  THEN 'NULL invoice, stock code or timestamp'
        ELSE 'unclassified'
    END
FROM classified c
WHERE c.exclusion_reason IS NOT NULL
GROUP BY c.exclusion_reason;

-- De-duplication is not a row-level exclusion, so it is recorded separately.
INSERT INTO core.fact_sales_exclusions
SELECT
    'duplicate_row',
    (SELECT COUNT(*) FROM staging.online_retail_raw) - (SELECT COUNT(*) FROM deduped),
    0,
    'Collapsed by natural key: sheet overlap 2010-12-01..2010-12-09 plus exact repeats';

COMMENT ON TABLE core.fact_sales IS
    'Invoice-line grain. Returns retained with negative quantity and '
    'is_return = TRUE so that headline revenue is net.';
COMMENT ON TABLE core.fact_sales_exclusions IS
    'Reconciliation ledger: staging rows = fact rows + every reason listed here.';

COMMIT;

\echo 'Fact table rebuilt.'
