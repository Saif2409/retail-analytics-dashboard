-- ============================================================================
-- 00_create_database.sql
-- Run against the maintenance database:
--   psql -U postgres -d postgres -f sql/00_create_database.sql
--
-- Idempotent: the \gexec trick runs the generated CREATE only when the
-- database is absent, because CREATE DATABASE cannot appear inside a
-- transaction block or an IF NOT EXISTS clause.
-- ============================================================================

SELECT 'CREATE DATABASE retail_analytics ENCODING ''UTF8'' TEMPLATE template0'
WHERE NOT EXISTS (
    SELECT 1 FROM pg_database WHERE datname = 'retail_analytics'
)\gexec

\echo 'Database retail_analytics is present.'
