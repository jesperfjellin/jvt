#!/bin/bash
# test_data_pipeline.sh - High-volume test data generator for JVT stress testing
# Generates thousands of random changes across the entire data bounds

set -euo pipefail

DATABASE_URL="${DATABASE_URL:-postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/gis}"

echo "$(date): Starting HIGH-VOLUME test data pipeline..."

# Configuration
BATCH_SIZE=1000  # Generate 1000 changes per run
TEST_ID_START=9000000  # Start test IDs from 9 million to avoid conflicts

# Get actual data bounds from database
echo "$(date): Detecting data bounds..."
BOUNDS=$(psql "$DATABASE_URL" -t -c "
WITH bounds AS (
    SELECT ST_Transform(ST_SetSRID(ST_Extent(way), 3857), 4326) as bbox
    FROM (
        SELECT way FROM planet_osm_point WHERE way IS NOT NULL
        UNION ALL 
        SELECT way FROM planet_osm_line WHERE way IS NOT NULL
        UNION ALL
        SELECT way FROM planet_osm_polygon WHERE way IS NOT NULL
    ) all_geom
)
SELECT 
    ST_XMin(bbox) as min_lon,
    ST_YMin(bbox) as min_lat,
    ST_XMax(bbox) as max_lon,
    ST_YMax(bbox) as max_lat
FROM bounds;
" | tr -d ' ' | tr '\n' ' ')

# Parse bounds
read -r MIN_LON MIN_LAT MAX_LON MAX_LAT <<< "$BOUNDS"

echo "$(date): Data bounds detected:"
echo "  Longitude: $MIN_LON to $MAX_LON"
echo "  Latitude: $MIN_LAT to $MAX_LAT"

# Generate random coordinates within bounds
generate_random_coords() {
    local lon_range=$(awk "BEGIN {print $MAX_LON - $MIN_LON}")
    local lat_range=$(awk "BEGIN {print $MAX_LAT - $MIN_LAT}")
    
    local rand_lon_offset=$(awk "BEGIN {print rand() * $lon_range}")
    local rand_lat_offset=$(awk "BEGIN {print rand() * $lat_range}")
    
    local test_lon=$(awk "BEGIN {printf \"%.6f\", $MIN_LON + $rand_lon_offset}")
    local test_lat=$(awk "BEGIN {printf \"%.6f\", $MIN_LAT + $rand_lat_offset}")
    
    echo "$test_lon $test_lat"
}

echo "$(date): Generating $BATCH_SIZE random changes across entire bounds..."

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