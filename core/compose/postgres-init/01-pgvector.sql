-- Runs only on a fresh data volume (Postgres docker entrypoint contract).
-- For an existing database, run these CREATE EXTENSION statements manually.
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pg_trgm;
