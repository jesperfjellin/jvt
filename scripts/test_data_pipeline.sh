#!/bin/bash
# test_data_pipeline.sh - Simple data injection/deletion pipeline for testing change detection
# This script simulates data changes to test our tile invalidation system

set -euo pipefail

DATABASE_URL="${DATABASE_URL:-postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/gis}"

echo "$(date): Starting test data pipeline..."

# Counter for unique test features
COUNTER_FILE="/tmp/jvt_test_counter"
if [ ! -f "$COUNTER_FILE" ]; then
    echo "0" > "$COUNTER_FILE"
fi

COUNTER=$(cat "$COUNTER_FILE")
NEXT_COUNTER=$((COUNTER + 1))
echo "$NEXT_COUNTER" > "$COUNTER_FILE"

# Test coordinates around Oslo, Norway (since we're using Norway data)
# Oslo center: approximately 59.9139, 10.7522
BASE_LAT=59.9139
BASE_LON=10.7522

# Generate random offsets (within ~10km of Oslo center)
# Use shell arithmetic instead of bc for simpler dependencies
RANDOM_LAT=$((RANDOM % 1000))  # 0-999
RANDOM_LON=$((RANDOM % 1000))  # 0-999

# Convert to decimal offsets: 0-999 -> -0.05 to +0.05 degrees (~10km range)
LAT_OFFSET=$(awk "BEGIN {printf \"%.6f\", ($RANDOM_LAT - 500) / 10000.0}")
LON_OFFSET=$(awk "BEGIN {printf \"%.6f\", ($RANDOM_LON - 500) / 10000.0}")

TEST_LAT=$(awk "BEGIN {printf \"%.6f\", $BASE_LAT + $LAT_OFFSET}")
TEST_LON=$(awk "BEGIN {printf \"%.6f\", $BASE_LON + $LON_OFFSET}")

echo "$(date): Test coordinates: $TEST_LAT, $TEST_LON"

# Randomly choose an operation
OPERATIONS=("INSERT" "UPDATE" "DELETE")
OPERATION=${OPERATIONS[$((RANDOM % 3))]}

echo "$(date): Performing operation: $OPERATION"

case $OPERATION in
    "INSERT")
        # Insert a new test point (using high positive IDs to avoid conflicts)
        TEST_ID=$((9000000 + NEXT_COUNTER))  # Start from 9 million to avoid real OSM IDs
        psql "$DATABASE_URL" << EOF
INSERT INTO planet_osm_point (osm_id, way, tags) 
VALUES (
    $TEST_ID,  -- High positive IDs for test data
    ST_Transform(ST_SetSRID(ST_MakePoint($TEST_LON, $TEST_LAT), 4326), 3857),
    'name => "JVT Test Point $NEXT_COUNTER", amenity => test'::hstore
);
EOF
        echo "$(date): Inserted test point $TEST_ID at ($TEST_LAT, $TEST_LON)"
        ;;
        
    "UPDATE")
        # Update an existing test point (if any exist)
        UPDATED=$(psql "$DATABASE_URL" -t -c "
UPDATE planet_osm_point 
SET way = ST_Transform(ST_SetSRID(ST_MakePoint($TEST_LON, $TEST_LAT), 4326), 3857),
    tags = tags || 'updated_at => $(date +%s)'::hstore
WHERE osm_id >= 9000000  -- Only update our test points
ORDER BY RANDOM() 
LIMIT 1
RETURNING osm_id;
" | tr -d ' ')
        
        if [ -n "$UPDATED" ] && [ "$UPDATED" != "" ]; then
            echo "$(date): Updated test point $UPDATED to ($TEST_LAT, $TEST_LON)"
        else
            echo "$(date): No test points available to update, skipping"
        fi
        ;;
        
    "DELETE")
        # Delete a random test point (if any exist)
        DELETED=$(psql "$DATABASE_URL" -t -c "
DELETE FROM planet_osm_point 
WHERE osm_id >= 9000000  -- Only delete our test points
  AND RANDOM() < 0.5  -- Only delete 50% of the time
RETURNING osm_id;
" | tr -d ' ')
        
        if [ -n "$DELETED" ] && [ "$DELETED" != "" ]; then
            echo "$(date): Deleted test point $DELETED"
        else
            echo "$(date): No test points available to delete, skipping"
        fi
        ;;
esac

# Show current pending tile count
PENDING_COUNT=$(psql "$DATABASE_URL" -t -c "
SELECT COUNT(DISTINCT (z, x, y)) 
FROM changed_tiles 
WHERE processed_at IS NULL;
" | tr -d ' ')

echo "$(date): Current pending tiles: $PENDING_COUNT"

# Show some recent changes for debugging
echo "$(date): Recent changes:"
psql "$DATABASE_URL" -c "
SELECT 
    z, x, y, 
    source_table, 
    operation, 
    changed_at,
    processed_at IS NULL as pending
FROM changed_tiles 
ORDER BY changed_at DESC 
LIMIT 5;
"

echo "$(date): Test data pipeline completed"