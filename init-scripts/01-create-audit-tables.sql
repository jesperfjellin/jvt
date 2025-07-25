-- Database initialization script for JVT project
-- Creates audit tables and optimizes PostgreSQL for OSM data

-- Enable PostGIS extension (required for OSM2PGSQL)
CREATE EXTENSION IF NOT EXISTS postgis;

-- Enable hstore extension (required for OSM tag storage)
CREATE EXTENSION IF NOT EXISTS hstore;

-- Create audit table for tracking tile processing batches
CREATE TABLE IF NOT EXISTS changed_tile_batches (
    id           BIGSERIAL PRIMARY KEY,
    first_z      SMALLINT,
    last_z       SMALLINT, 
    tile_count   INTEGER,
    started_at   TIMESTAMPTZ,
    finished_at  TIMESTAMPTZ,
    source_file  TEXT
);

-- Index for efficient querying of batch history
CREATE INDEX IF NOT EXISTS idx_changed_tile_batches_started_at 
ON changed_tile_batches(started_at);

-- Create notification channel for tile updates
-- (The Rust worker will listen on this channel)
-- Note: LISTEN/NOTIFY channels are created automatically when first used

-- Optimize PostgreSQL settings for OSM data processing
-- These complement the settings in docker-compose.yml

-- Enable auto vacuum for large tables
ALTER SYSTEM SET autovacuum = on;
ALTER SYSTEM SET autovacuum_max_workers = 4;

-- Optimize for bulk data operations
ALTER SYSTEM SET synchronous_commit = off;
ALTER SYSTEM SET fsync = off;  -- WARNING: Only for initial import, re-enable for production

-- Configure work memory for large operations  
ALTER SYSTEM SET work_mem = '128MB';  -- Reduced to prevent memory buildup
ALTER SYSTEM SET max_wal_size = '4GB';

-- Memory management for long-running imports
ALTER SYSTEM SET shared_buffers = '1GB';  -- Limit PostgreSQL cache
ALTER SYSTEM SET effective_cache_size = '2GB';  -- Conservative estimate
ALTER SYSTEM SET checkpoint_completion_target = 0.9;  -- Spread out writes
ALTER SYSTEM SET checkpoint_timeout = '10min';  -- More frequent checkpoints

-- Reload configuration
SELECT pg_reload_conf(); 