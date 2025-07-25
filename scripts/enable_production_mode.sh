#!/bin/bash
# enable_production_mode.sh - Transition PostgreSQL from import mode to production mode
# CRITICAL: Run this script after planet import completes but BEFORE starting minutely updates

set -euo pipefail

DATABASE_URL="${DATABASE_URL:-postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/gis}"

echo "$(date): Transitioning PostgreSQL to production mode..."
echo "WARNING: This will re-enable ACID compliance (fsync, synchronous_commit)"
echo "This is REQUIRED for data safety during minutely updates."
echo

# Re-enable production safety settings
echo "$(date): Re-enabling fsync and synchronous_commit..."

psql "$DATABASE_URL" << 'EOF'
-- Re-enable ACID compliance for production use
ALTER SYSTEM SET fsync = on;                    -- Enable disk synchronization
ALTER SYSTEM SET synchronous_commit = on;       -- Enable transaction durability

-- Optimize for frequent small updates (minutely diffs)
ALTER SYSTEM SET work_mem = '64MB';              -- Reduce for many small operations
ALTER SYSTEM SET checkpoint_timeout = '5min';   -- More frequent checkpoints for updates
ALTER SYSTEM SET wal_buffers = '16MB';          -- Optimize for small frequent writes

-- Reload configuration
SELECT pg_reload_conf();

-- Verify settings
SELECT name, setting, pending_restart 
FROM pg_settings 
WHERE name IN ('fsync', 'synchronous_commit', 'work_mem', 'checkpoint_timeout');

EOF

echo "$(date): Production mode enabled successfully!"
echo
echo "NEXT STEPS:"
echo "1. Restart PostgreSQL container: docker compose restart postgres"
echo "2. Verify replication initialization: osm2pgsql-replication status"
echo "3. Test minutely updates: scripts/update_tiles.sh"
echo "4. Start Rust worker for tile generation" 