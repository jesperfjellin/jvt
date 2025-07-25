#!/bin/bash
# import_planet.sh - Initial planet import script for JVT project
# This script imports the planet-latest.osm.pbf file into PostgreSQL

set -euo pipefail

# Configuration
DATABASE_URL="${DATABASE_URL:-postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/gis}"
PLANET_FILE="${PLANET_FILE:-/data/osm/planet/planet-latest.osm.pbf}"
CACHE_SIZE="${CACHE_SIZE:-4000}"  # MB - reduced for memory safety
PROCESSES="${PROCESSES:-2}"       # Number of parallel processes - reduced

echo "$(date): Starting planet import..."
echo "Planet file: $PLANET_FILE"
echo "Database: $DATABASE_URL"
echo "Cache size: ${CACHE_SIZE}MB"
echo "Processes: $PROCESSES"

# Check if planet file exists
if [ ! -f "$PLANET_FILE" ]; then
    echo "ERROR: Planet file not found at $PLANET_FILE"
    echo "Expected location inside container: /data/osm/planet/planet-latest.osm.pbf"
    echo "Make sure your planet file is mapped correctly in docker-compose.yml"
    exit 1
fi

# Get file size for progress tracking
PLANET_SIZE=$(du -h "$PLANET_FILE" | cut -f1)
echo "Planet file size: $PLANET_SIZE"

# Create database if it doesn't exist (should be handled by postgres container)
DB_NAME="${DATABASE_URL##*/}"
echo "Using database: $DB_NAME"

# Run the import
echo "$(date): Starting OSM2PGSQL import (this will take several hours)..."

osm2pgsql \
    --create \
    --slim \
    --drop \
    --cache="$CACHE_SIZE" \
    --number-processes="$PROCESSES" \
    --hstore \
    --multi-geometry \
    --keep-coastlines \
    --flat-nodes=/tmp/flat-nodes.cache \
    --database="$DATABASE_URL" \
    --verbose \
    "$PLANET_FILE"

echo "$(date): Planet import completed successfully!"

# Initialize replication (following docs/OSM2PGSQL.txt)
echo "$(date): Initializing minutely replication..."

osm2pgsql-replication init \
    --database="$DATABASE_URL" \
    --server https://planet.openstreetmap.org/replication/minute

echo "$(date): Replication initialized. Ready for minutely updates!"

# Show database size
echo "$(date): Database import statistics:"
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

echo "$(date): Setup complete! You can now run update_tiles.sh for minutely updates." 