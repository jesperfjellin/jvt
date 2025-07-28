#!/bin/bash
# import_norway.sh - Norway OSM data import script for JVT project
# This script imports norway-latest.osm.pbf into PostgreSQL with replication support

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

# Initialize replication (following docs/OSM2PGSQL.txt)
echo "$(date): Initializing minutely replication for Norway..."

osm2pgsql-replication init \
    --database="$DATABASE_URL" \
    --server https://planet.openstreetmap.org/replication/minute

echo "$(date): Replication initialized. Ready for minutely updates!"

# Show database size
echo "$(date): Norway database import statistics:"
psql "$DATABASE_URL" -c "
SELECT 
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size
FROM pg_tables 
WHERE schemaname = 'public' 
    AND tablename LIKE 'planet_osm_%'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
"

echo "$(date): Norway setup complete! You can now run update_tiles.sh for minutely updates." 