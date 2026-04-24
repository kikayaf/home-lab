-- =============================================================================
-- Enable pgvector extension in the default postgres database
-- =============================================================================
-- This file runs ONCE on first container boot, when Postgres is initialising
-- its data directory (PGDATA empty). On subsequent boots the file is ignored.
--
-- For new databases created later (e.g. CREATE DATABASE workflows_db), you
-- have to re-run CREATE EXTENSION vector inside THAT database:
--     \c workflows_db
--     CREATE EXTENSION IF NOT EXISTS vector;
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS vector;
