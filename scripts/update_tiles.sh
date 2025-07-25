#!/bin/bash
# update_tiles.sh - OSM2PGSQL replication script for JVT project
# Based on development.yaml specifications

set -euo pipefail

# Configuration from environment variables
DATABASE_URL="${DATABASE_URL:-postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/gis}"
DIRTY_TILES_DIR="${DIRTY_TILES_PATH:-/var/cache/renderd}"
MAX_DIFF_SIZE="${MAX_DIFF_SIZE_MB:-50}"
EXPIRE_TILES_ZOOM="${EXPIRE_TILES_ZOOM:-0-14}"

# Create timestamp for this run
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
DIRTY_TILES_FILE="${DIRTY_TILES_DIR}/dirty_tiles.${TIMESTAMP}.txt"

# Ensure directories exist
mkdir -p "$DIRTY_TILES_DIR"

echo "$(date): Starting OSM2PGSQL replication update..."

# Run osm2pgsql-replication update with expire output
# This follows the exact pattern from docs/OSM2PGSQL.txt
osm2pgsql-replication update \
  --database="${DATABASE_URL}" \
  --max-diff-size="${MAX_DIFF_SIZE}" \
  --expire-tiles="${EXPIRE_TILES_ZOOM}" \
  --expire-output="${DIRTY_TILES_FILE}" \
  -- \
  --slim \
  --drop \
  --cache=4000 \
  --number-processes=4 \
  --hstore \
  --multi-geometry \
  --keep-coastlines \
  --database="${DATABASE_URL#postgresql://*/}"

# Check if dirty tiles file was created and has content
if [ -f "$DIRTY_TILES_FILE" ] && [ -s "$DIRTY_TILES_FILE" ]; then
    TILE_COUNT=$(wc -l < "$DIRTY_TILES_FILE")
    echo "$(date): Found $TILE_COUNT dirty tiles, notifying worker..."
    
    # Notify Rust worker that new tiles are ready
    # The notification payload contains the filename
    psql "$DATABASE_URL" -c "NOTIFY tiles_updated, '$DIRTY_TILES_FILE';"
    
    echo "$(date): Update complete, notification sent"
else
    echo "$(date): No tiles to update (dirty_tiles.txt empty or missing)"
fi

# Clean up old dirty tile files (keep last 10)
find "$DIRTY_TILES_DIR" -name "dirty_tiles.*.txt" -type f | \
    sort -r | tail -n +11 | xargs -r rm -f

echo "$(date): OSM2PGSQL replication update finished" 