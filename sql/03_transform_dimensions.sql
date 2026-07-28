-- ============================================================================
-- 03_transform_dimensions.sql   -- build the conformed dimensions
-- Run against retail_analytics, after 02_load_staging.sql.
--
-- Rebuilds all four dimensions from scratch on every run. The dataset is a
-- fixed historical extract, so a full rebuild is simpler, faster and easier to
-- reason about than incremental merge logic.
-- ============================================================================

BEGIN;

DROP TABLE IF EXISTS core.fact_sales   CASCADE;
DROP TABLE IF EXISTS core.dim_date     CASCADE;
DROP TABLE IF EXISTS core.dim_country  CASCADE;
DROP TABLE IF EXISTS core.dim_customer CASCADE;
DROP TABLE IF EXISTS core.dim_product  CASCADE;


-- ============================================================================
-- dim_date
--
-- Spans whole calendar years, not just the observed min..max. This is not
-- cosmetic: Power BI time-intelligence functions (SAMEPERIODLASTYEAR, DATEADD,
-- TOTALYTD) silently return blank against a date table with partial years or
-- gaps. Contiguous 1 Jan -> 31 Dec coverage is a hard requirement for the
-- YoY measures in dax/measures.md.
-- ============================================================================

CREATE TABLE core.dim_date (
    date_key        integer     PRIMARY KEY,          -- yyyymmdd
    full_date       date        NOT NULL UNIQUE,
    year            smallint    NOT NULL,
    quarter         smallint    NOT NULL,
    quarter_name    text        NOT NULL,             -- 'Q1'
    year_quarter    text        NOT NULL,             -- '2010-Q1'
    month           smallint    NOT NULL,
    month_name      text        NOT NULL,             -- 'January'
    month_short     text        NOT NULL,             -- 'Jan'
    year_month      char(7)     NOT NULL,             -- '2010-01', sorts correctly
    month_start     date        NOT NULL,
    month_end       date        NOT NULL,
    day_of_month    smallint    NOT NULL,
    day_of_week     smallint    NOT NULL,             -- 1 = Monday .. 7 = Sunday
    day_name        text        NOT NULL,
    day_short       text        NOT NULL,
    week_of_year    smallint    NOT NULL,             -- ISO week
    day_of_year     smallint    NOT NULL,
    is_weekend      boolean     NOT NULL,
    is_complete_month boolean   NOT NULL              -- see note below
);

-- is_complete_month exists because the extract stops mid-month, on 2011-12-09.
-- Left unflagged, December 2011 shows nine days of trading against a full
-- December 2010 and the YoY measure reports a ~70% collapse that never
-- happened. This is the single most common way a retail dashboard lies. The
-- report defaults to is_complete_month = TRUE and the partial month is called
-- out explicitly rather than quietly dropped.

INSERT INTO core.dim_date
WITH bounds AS (
    SELECT
        make_date(EXTRACT(YEAR FROM MIN(invoice_ts))::int, 1, 1)   AS from_date,
        make_date(EXTRACT(YEAR FROM MAX(invoice_ts))::int, 12, 31) AS to_date,
        MAX(invoice_ts)::date                                      AS last_txn_date
    FROM staging.online_retail_raw
    WHERE invoice_ts IS NOT NULL
),
calendar AS (
    SELECT g.d::date AS d, b.last_txn_date
    FROM bounds b
    CROSS JOIN generate_series(b.from_date, b.to_date, interval '1 day') AS g(d)
)
SELECT
    (to_char(d, 'YYYYMMDD'))::int,
    d,
    EXTRACT(YEAR    FROM d)::smallint,
    EXTRACT(QUARTER FROM d)::smallint,
    'Q' || EXTRACT(QUARTER FROM d)::text,
    to_char(d, 'YYYY') || '-Q' || EXTRACT(QUARTER FROM d)::text,
    EXTRACT(MONTH FROM d)::smallint,
    trim(to_char(d, 'Month')),
    to_char(d, 'Mon'),
    to_char(d, 'YYYY-MM'),
    date_trunc('month', d)::date,
    (date_trunc('month', d) + interval '1 month - 1 day')::date,
    EXTRACT(DAY FROM d)::smallint,
    EXTRACT(ISODOW FROM d)::smallint,
    trim(to_char(d, 'Day')),
    to_char(d, 'Dy'),
    EXTRACT(WEEK FROM d)::smallint,
    EXTRACT(DOY  FROM d)::smallint,
    EXTRACT(ISODOW FROM d) >= 6,
    (date_trunc('month', d) + interval '1 month - 1 day')::date <= last_txn_date
FROM calendar;

COMMENT ON TABLE core.dim_date IS
    'Contiguous daily calendar covering whole years. Required by Power BI time '
    'intelligence -- mark as the date table on full_date.';


-- ============================================================================
-- dim_country
--
-- ISO-2 codes are added so Power BI maps resolve unambiguously; passing raw
-- names to a map visual mis-plots the non-standard ones. Three source values
-- are not countries at all ('Unspecified', 'European Community', plus the
-- shorthand 'EIRE' and 'RSA') and are normalised here rather than in the fact.
-- ============================================================================

CREATE TABLE core.dim_country (
    country_key     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    country_name    text    NOT NULL UNIQUE,   -- as it appears in the source
    country_clean   text    NOT NULL,          -- normalised display name
    iso2            char(2),                   -- NULL when not a real country
    region          text    NOT NULL,
    is_domestic     boolean NOT NULL           -- retailer is UK-based
);

INSERT INTO core.dim_country (country_name, country_clean, iso2, region, is_domestic)
SELECT
    c.country,
    CASE c.country
        WHEN 'EIRE' THEN 'Ireland'
        WHEN 'RSA'  THEN 'South Africa'
        WHEN 'USA'  THEN 'United States'
        WHEN 'Korea' THEN 'South Korea'
        WHEN 'Channel Islands' THEN 'Channel Islands'
        WHEN 'West Indies'     THEN 'West Indies'
        WHEN 'Unspecified'         THEN 'Unspecified'
        WHEN 'European Community'  THEN 'Unspecified'
        ELSE c.country
    END,
    CASE c.country
        WHEN 'United Kingdom' THEN 'GB' WHEN 'EIRE'        THEN 'IE'
        WHEN 'France'         THEN 'FR' WHEN 'Germany'     THEN 'DE'
        WHEN 'Netherlands'    THEN 'NL' WHEN 'Spain'       THEN 'ES'
        WHEN 'Portugal'       THEN 'PT' WHEN 'Italy'       THEN 'IT'
        WHEN 'Belgium'        THEN 'BE' WHEN 'Switzerland' THEN 'CH'
        WHEN 'Austria'        THEN 'AT' WHEN 'Norway'      THEN 'NO'
        WHEN 'Sweden'         THEN 'SE' WHEN 'Denmark'     THEN 'DK'
        WHEN 'Finland'        THEN 'FI' WHEN 'Iceland'     THEN 'IS'
        WHEN 'Poland'         THEN 'PL' WHEN 'Lithuania'   THEN 'LT'
        WHEN 'Czech Republic' THEN 'CZ' WHEN 'Greece'      THEN 'GR'
        WHEN 'Cyprus'         THEN 'CY' WHEN 'Malta'       THEN 'MT'
        WHEN 'Israel'         THEN 'IL' WHEN 'Lebanon'     THEN 'LB'
        WHEN 'Bahrain'        THEN 'BH' WHEN 'Saudi Arabia' THEN 'SA'
        WHEN 'United Arab Emirates' THEN 'AE'
        WHEN 'Japan'          THEN 'JP' WHEN 'Singapore'   THEN 'SG'
        WHEN 'Hong Kong'      THEN 'HK' WHEN 'Korea'       THEN 'KR'
        WHEN 'Thailand'       THEN 'TH' WHEN 'Australia'   THEN 'AU'
        WHEN 'Canada'         THEN 'CA' WHEN 'USA'         THEN 'US'
        WHEN 'Brazil'         THEN 'BR' WHEN 'Bermuda'     THEN 'BM'
        WHEN 'Nigeria'        THEN 'NG' WHEN 'RSA'         THEN 'ZA'
        WHEN 'Channel Islands' THEN 'JE'
        ELSE NULL
    END,
    CASE
        WHEN c.country = 'United Kingdom' THEN 'United Kingdom'
        WHEN c.country IN ('EIRE','France','Germany','Netherlands','Spain','Portugal',
                           'Italy','Belgium','Switzerland','Austria','Norway','Sweden',
                           'Denmark','Finland','Iceland','Poland','Lithuania',
                           'Czech Republic','Greece','Cyprus','Malta','Channel Islands')
             THEN 'Europe'
        WHEN c.country IN ('Israel','Lebanon','Bahrain','Saudi Arabia',
                           'United Arab Emirates')
             THEN 'Middle East'
        WHEN c.country IN ('Japan','Singapore','Hong Kong','Korea','Thailand')
             THEN 'Asia Pacific'
        WHEN c.country IN ('Australia') THEN 'Asia Pacific'
        WHEN c.country IN ('Canada','USA','Brazil','Bermuda','West Indies')
             THEN 'Americas'
        WHEN c.country IN ('Nigeria','RSA') THEN 'Africa'
        ELSE 'Unspecified'
    END,
    c.country = 'United Kingdom'
FROM (SELECT DISTINCT country FROM staging.online_retail_raw WHERE country IS NOT NULL) c
ORDER BY c.country;

COMMENT ON TABLE core.dim_country IS
    'Ship-to country. Lives on the fact rather than only on the customer, '
    'because guest rows have no customer but always have a country.';


-- ============================================================================
-- dim_product
--
-- Two things are resolved here:
--
-- 1. Service lines. Real SKUs match ^[0-9]{5} (e.g. 22423, 85123A, 84406B).
--    Everything else is a service or accounting line -- POST, DOT, C2, M, D,
--    BANK CHARGES, AMAZONFEE, S, ADJUST, TEST001, CRUK, gift vouchers. They
--    are kept as rows and flagged, never silently deleted, so the exclusion
--    stays auditable.
--
-- 2. Description drift. The same SKU carries several spellings across 1M rows,
--    plus outright NULLs. The most frequent non-null description wins, with
--    ties broken by length for determinism.
--
-- product_category is DERIVED, not sourced -- the dataset ships no category
-- column. It is a documented keyword heuristic whose only purpose is to give
-- the Power BI report a Category -> Product drill-down path. It is approximate
-- and labelled as such in the report.
-- ============================================================================

CREATE TABLE core.dim_product (
    product_key      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    stock_code       text    NOT NULL UNIQUE,
    description      text    NOT NULL,
    product_category text    NOT NULL,
    is_service_line  boolean NOT NULL
);

INSERT INTO core.dim_product (stock_code, description, product_category, is_service_line)
WITH ranked_description AS (
    SELECT
        upper(trim(stock_code))              AS stock_code,
        trim(description)                    AS description,
        ROW_NUMBER() OVER (
            PARTITION BY upper(trim(stock_code))
            ORDER BY COUNT(*) DESC, length(trim(description)) DESC, trim(description)
        ) AS rn
    FROM staging.online_retail_raw
    WHERE stock_code  IS NOT NULL
      AND description IS NOT NULL
      AND trim(description) <> ''
    GROUP BY upper(trim(stock_code)), trim(description)
),
all_codes AS (
    SELECT DISTINCT upper(trim(stock_code)) AS stock_code
    FROM staging.online_retail_raw
    WHERE stock_code IS NOT NULL
)
SELECT
    a.stock_code,
    COALESCE(r.description, 'Unknown'),
    CASE
        WHEN a.stock_code !~ '^[0-9]{5}' THEN 'Service / Adjustment'
        WHEN r.description IS NULL       THEN 'Uncategorised'
        WHEN r.description ~* 'CHRISTMAS|XMAS|ADVENT|SANTA|REINDEER' THEN 'Christmas'
        WHEN r.description ~* 'BAG|SHOPPER|SATCHEL|LUNCH BOX|WRAP'   THEN 'Bags & Wrap'
        WHEN r.description ~* 'CANDLE|T-LIGHT|TEA ?LIGHT|LANTERN|LIGHT HOLDER'
                                                                     THEN 'Candles & Lighting'
        WHEN r.description ~* 'MUG|PLATE|BOWL|CUTLERY|TEAPOT|JUG|CAKE|BAKING|KITCHEN|APRON|JAR|TIN'
                                                                     THEN 'Kitchen & Dining'
        WHEN r.description ~* 'GARDEN|PLANTER|WATERING|BIRD|FLOWER|HERB'
                                                                     THEN 'Garden & Outdoor'
        WHEN r.description ~* 'CARD|NOTEBOOK|PENCIL|PEN |CHALK|STICKER|CRAYON|PAPER'
                                                                     THEN 'Stationery & Craft'
        WHEN r.description ~* 'TOY|GAME|PUZZLE|DOLL|SKITTLE|PLAYHOUSE|BUNTING|CHILD'
                                                                     THEN 'Toys & Games'
        WHEN r.description ~* 'CUSHION|FRAME|CLOCK|MIRROR|HOOK|DOORMAT|CABINET|DRAWER|SIGN|HEART|DECORATION|ORNAMENT'
                                                                     THEN 'Home Decor'
        WHEN r.description ~* 'NECKLACE|BRACELET|EARRING|RING|SCARF|JEWEL|PURSE'
                                                                     THEN 'Jewellery & Accessories'
        ELSE 'Other'
    END,
    a.stock_code !~ '^[0-9]{5}'
FROM all_codes a
LEFT JOIN ranked_description r
       ON r.stock_code = a.stock_code AND r.rn = 1;

COMMENT ON COLUMN core.dim_product.product_category IS
    'DERIVED via keyword heuristic -- the source has no category column. '
    'Approximate; intended for drill-down navigation, not for financial reporting.';
COMMENT ON COLUMN core.dim_product.is_service_line IS
    'TRUE for non-merchandise lines (postage, discounts, bank charges, manual '
    'adjustments, test rows). Excluded from core.fact_sales.';


-- ============================================================================
-- dim_customer
--
-- Key -1 is the reserved "Guest / Unknown" member. Roughly a fifth of source
-- rows have no customer id; mapping them to a real dimension member keeps the
-- fact's foreign key NOT NULL and stops Power BI from quietly dropping that
-- revenue from customer-sliced visuals. Their revenue is real and must show up.
--
-- Country is the customer's most frequent ship-to country -- a handful of
-- customers appear against more than one.
-- ============================================================================

CREATE TABLE core.dim_customer (
    customer_key      integer PRIMARY KEY,        -- natural id; -1 = guest
    customer_id       integer UNIQUE,             -- NULL for the guest member
    customer_label    text    NOT NULL,
    country_key       integer REFERENCES core.dim_country (country_key),
    is_known_customer boolean NOT NULL
);

INSERT INTO core.dim_customer
    (customer_key, customer_id, customer_label, country_key, is_known_customer)
VALUES (-1, NULL, 'Guest / Unknown', NULL, false);

INSERT INTO core.dim_customer
    (customer_key, customer_id, customer_label, country_key, is_known_customer)
WITH dominant_country AS (
    SELECT
        r.customer_id,
        r.country,
        ROW_NUMBER() OVER (
            PARTITION BY r.customer_id
            ORDER BY COUNT(*) DESC, r.country
        ) AS rn
    FROM staging.online_retail_raw r
    WHERE r.customer_id IS NOT NULL
      AND r.country     IS NOT NULL
    GROUP BY r.customer_id, r.country
)
SELECT
    d.customer_id,
    d.customer_id,
    'Customer ' || d.customer_id::text,
    c.country_key,
    true
FROM dominant_country d
JOIN core.dim_country c ON c.country_name = d.country
WHERE d.rn = 1;

COMMENT ON TABLE core.dim_customer IS
    'One row per identifiable customer, plus reserved key -1 for guest '
    'checkouts so that unattributed revenue is never dropped from the report.';

COMMIT;

\echo 'Dimensions rebuilt.'
