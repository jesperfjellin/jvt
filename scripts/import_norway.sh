#!/bin/bash
# import_norway.sh - Norway OSM data import script for JVT project
# This script imports norway-latest.osm.pbf into PostgreSQL

set -euo pipefail

# Configuration
DATABASE_URL="${DATABASE_URL:-postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/gis}"
NORWAY_FILE="${NORWAY_FILE:-/data/osm/norway/norway-latest.osm.pbf}"
CACHE_SIZE="${CACHE_SIZE:-4000}"  # MB - smaller cache for Norway data
PROCESSES="${PROCESSES:-4}"       # Number of parallel processes

echo "$(date): Starting Norway OSM data import..."
echo "Norway file: $NORWAY_FILE"
echo "Database: $DATABASE_URL"
echo "Cache size: ${CACHE_SIZE}MB"
echo "Processes: $PROCESSES"

# Check if Norway file exists
if [ ! -f "$NORWAY_FILE" ]; then
    echo "ERROR: Norway file not found at $NORWAY_FILE"
    echo "Expected location inside container: /data/osm/norway-latest.osm.pbf"
    echo "Download with: wget https://download.geofabrik.de/europe/norway-latest.osm.pbf"
    echo "Make sure your file is mapped correctly in docker-compose.yml"
    exit 1
fi

# Get file size for progress tracking
NORWAY_SIZE=$(du -h "$NORWAY_FILE" | cut -f1)
echo "Norway file size: $NORWAY_SIZE"

# Create database if it doesn't exist (should be handled by postgres container)
DB_NAME="${DATABASE_URL##*/}"
echo "Using database: $DB_NAME"

# Run the import
echo "$(date): Starting OSM2PGSQL import (should complete in 10-30 minutes)..."

osm2pgsql \
    --create \
    --slim \
    --cache="$CACHE_SIZE" \
    --number-processes="$PROCESSES" \
    --hstore \
    --multi-geometry \
    --keep-coastlines \
    --flat-nodes=/tmp/flat-nodes.cache \
    --database="$DATABASE_URL" \
    --verbose \
    "$NORWAY_FILE"

echo "$(date): Norway import completed successfully!"

# Show database size and verify table names
echo "$(date): Norway database import statistics:"
psql "$DATABASE_URL" -c "
SELECT 
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size,
    (SELECT COUNT(*) FROM information_schema.tables WHERE table_name = tablename) as row_count_check
FROM pg_tables 
WHERE schemaname = 'public' 
    AND tablename LIKE 'planet_osm_%'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
"

echo "$(date): Confirming osm2pgsql created tables with 'planet_osm_' prefix even for Norway data"

echo "$(date): Norway setup complete! The JVT worker will detect changes via database triggers." 