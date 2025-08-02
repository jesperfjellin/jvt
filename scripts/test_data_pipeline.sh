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

# Get bounds using simpler query (just use planet_osm_polygon for extent since it covers most area)
BOUNDS_QUERY="
WITH bounds AS (
    SELECT ST_Transform(ST_SetSRID(ST_Extent(way), 3857), 4326) as bbox
    FROM planet_osm_polygon 
    WHERE way IS NOT NULL
)
SELECT 
    ST_XMin(bbox) as min_lon,
    ST_YMin(bbox) as min_lat,
    ST_XMax(bbox) as max_lon,
    ST_YMax(bbox) as max_lat
FROM bounds;
"

# Get all bounds in one query
BOUNDS_RESULT=$(psql "$DATABASE_URL" -t -A -c "$BOUNDS_QUERY")

# Parse the pipe-separated result
IFS='|' read -r MIN_LON MIN_LAT MAX_LON MAX_LAT <<< "$BOUNDS_RESULT"

echo "$(date): Data bounds detected:"
echo "  Longitude: $MIN_LON to $MAX_LON"
echo "  Latitude: $MIN_LAT to $MAX_LAT"

# Generate random coordinates within bounds
generate_random_coords() {
    # Use shell RANDOM's actual range (0-32767)
    local random_val1=$RANDOM  # 0-32767
    local random_val2=$RANDOM  # 0-32767
    
    # Convert to 0.0-1.0 range and calculate coordinates
    local test_lon=$(awk -v min="$MIN_LON" -v max="$MAX_LON" -v rval="$random_val1" \
                     'BEGIN {printf "%.6f", min + (max - min) * (rval / 32767.0)}')
    local test_lat=$(awk -v min="$MIN_LAT" -v max="$MAX_LAT" -v rval="$random_val2" \
                     'BEGIN {printf "%.6f", min + (max - min) * (rval / 32767.0)}')
    
    echo "$test_lon $test_lat"
}

# Get a counter for unique IDs
COUNTER_FILE="/tmp/jvt_test_counter"
if [ ! -f "$COUNTER_FILE" ]; then
    echo "0" > "$COUNTER_FILE"
fi
COUNTER=$(cat "$COUNTER_FILE")

# Generate bulk operations
INSERTS=0
UPDATES=0
DELETES=0

echo "$(date): Starting bulk operations..."

# 1. BULK INSERTS (70% of operations)
INSERT_COUNT=$((BATCH_SIZE * 70 / 100))
echo "$(date): Performing $INSERT_COUNT bulk inserts..."

for i in $(seq 1 $INSERT_COUNT); do
    COORDS=$(generate_random_coords)
    read -r LON LAT <<< "$COORDS"
    TEST_ID=$((TEST_ID_START + COUNTER + i))
    
    psql "$DATABASE_URL" -c "
    INSERT INTO planet_osm_point (osm_id, way, tags) 
    VALUES (
        $TEST_ID,
        ST_Transform(ST_SetSRID(ST_MakePoint($LON, $LAT), 4326), 3857),
        'name => \"JVT Stress Test $TEST_ID\", test_batch => \"$(date +%s)\", amenity => \"test\"'::hstore
    );" > /dev/null
    
    INSERTS=$((INSERTS + 1))
done

# 2. BULK UPDATES (20% of operations)
UPDATE_COUNT=$((BATCH_SIZE * 20 / 100))
echo "$(date): Performing $UPDATE_COUNT bulk updates..."

for i in $(seq 1 $UPDATE_COUNT); do
    COORDS=$(generate_random_coords)
    read -r LON LAT <<< "$COORDS"
    
    UPDATED=$(psql "$DATABASE_URL" -t -c "
    UPDATE planet_osm_point 
    SET way = ST_Transform(ST_SetSRID(ST_MakePoint($LON, $LAT), 4326), 3857),
        tags = tags || 'updated_at => \"$(date +%s)\"'::hstore
    WHERE osm_id >= $TEST_ID_START
      AND RANDOM() < 0.1  -- Update 10% of existing test points
    RETURNING osm_id;
    " | head -1 | tr -d ' ')
    
    if [ -n "$UPDATED" ] && [ "$UPDATED" != "" ]; then
        UPDATES=$((UPDATES + 1))
    fi
done

# 3. BULK DELETES (10% of operations)
DELETE_COUNT=$((BATCH_SIZE * 10 / 100))
echo "$(date): Performing $DELETE_COUNT bulk deletes..."

for i in $(seq 1 $DELETE_COUNT); do
    DELETED=$(psql "$DATABASE_URL" -t -c "
    DELETE FROM planet_osm_point 
    WHERE osm_id >= $TEST_ID_START
      AND RANDOM() < 0.05  -- Delete 5% of existing test points
    RETURNING osm_id;
    " | head -1 | tr -d ' ')
    
    if [ -n "$DELETED" ] && [ "$DELETED" != "" ]; then
        DELETES=$((DELETES + 1))
    fi
done

# Update counter
echo $((COUNTER + INSERT_COUNT)) > "$COUNTER_FILE"

# Show comprehensive statistics
echo ""
echo "$(date): BULK OPERATION SUMMARY:"
echo "  Inserts: $INSERTS / $INSERT_COUNT"
echo "  Updates: $UPDATES / $UPDATE_COUNT" 
echo "  Deletes: $DELETES / $DELETE_COUNT"
echo "  Total changes: $((INSERTS + UPDATES + DELETES))"

# Show pending tile count
PENDING_COUNT=$(psql "$DATABASE_URL" -t -c "
SELECT COUNT(DISTINCT (z, x, y)) 
FROM changed_tiles 
WHERE processed_at IS NULL;
" | tr -d ' ')

echo "  Pending tiles: $PENDING_COUNT"

# Show recent tile activity (top 10 most affected tiles)
echo ""
echo "$(date): Top affected tiles:"
psql "$DATABASE_URL" -c "
SELECT z, x, y, COUNT(*) as change_count,
       MIN(changed_at) as first_change,
       MAX(changed_at) as last_change,
       CASE WHEN MAX(processed_at) IS NULL THEN 'PENDING' 
            WHEN MAX(processed_at) > NOW() - INTERVAL '5 minutes' THEN 'FRESH'
            ELSE 'STALE' END as status
FROM changed_tiles 
WHERE changed_at > NOW() - INTERVAL '10 minutes'
GROUP BY z, x, y
ORDER BY change_count DESC, last_change DESC
LIMIT 10;
"

# Show test data count
TEST_DATA_COUNT=$(psql "$DATABASE_URL" -t -c "
SELECT COUNT(*) FROM planet_osm_point WHERE osm_id >= $TEST_ID_START;
" | tr -d ' ')

echo ""
echo "$(date): Total test data points in database: $TEST_DATA_COUNT"
echo "$(date): HIGH-VOLUME test data pipeline completed"
echo "$(date): Ready for next batch in 60 seconds..."