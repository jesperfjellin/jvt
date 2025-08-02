#!/bin/bash
# synthetic_global_generator.sh - Generate global synthetic demo data
# Much simpler than OSM approach - uses PostGIS functions directly

set -euo pipefail

DATABASE_URL="${DATABASE_URL:-postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/gis}"

echo "$(date): Starting synthetic global data generation..."

# Configuration for global coverage
ZOOM_LEVEL=8               # z8 = 256x256 tiles
TOTAL_TILES=$((256 * 256))  # 65,536 tiles
POINTS_PER_TILE=2          # 2 points per tile for demo
BATCH_SIZE=1000            # Process tiles in batches

echo "$(date): Generating synthetic data for $TOTAL_TILES tiles at zoom $ZOOM_LEVEL"

# Reset any existing synthetic data
echo "$(date): Resetting existing synthetic data..."
psql "$DATABASE_URL" -c "SELECT reset_synthetic_demo();" > /dev/null

# Generate synthetic data using PostGIS functions (much easier!)
echo "$(date): Generating global synthetic coverage..."

# Test the function first
echo "$(date): Testing generate_tile_test_data function..."
TEST_RESULT=$(psql "$DATABASE_URL" -t -c "
DO \$\$
BEGIN
    PERFORM generate_tile_test_data(0, 50, $ZOOM_LEVEL, $POINTS_PER_TILE);
    RAISE NOTICE 'Test tile generation successful';
END
\$\$;
SELECT COUNT(*) FROM demo_points;
" 2>&1)

echo "$(date): Test result: $TEST_RESULT"

if echo "$TEST_RESULT" | grep -q "ERROR"; then
    echo "$(date): ERROR in function test: $TEST_RESULT"
    exit 1
fi

PROCESSED=0
for x in $(seq 0 4); do  # DEBUG: Only process first 5 columns for testing
    echo "$(date): Processing tile column $x/4 (DEBUG: limited to 5 columns)..."
    
    # Generate entire column of tiles in one batch (efficient!)
    COLUMN_RESULT=$(psql "$DATABASE_URL" -c "
    DO \$\$
    DECLARE
        y_coord integer;
        generated_count integer := 0;
    BEGIN
        FOR y_coord IN 20..235 LOOP  -- Skip extreme polar regions
            BEGIN
                -- Generate test data for this tile
                PERFORM generate_tile_test_data($x, y_coord, $ZOOM_LEVEL, $POINTS_PER_TILE);
                generated_count := generated_count + 1;
                
                -- Progress update every 50 tiles
                IF generated_count % 50 = 0 THEN
                    RAISE NOTICE 'Column $x: Generated % tiles', generated_count;
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    RAISE WARNING 'Failed to generate tile $x,% : %', y_coord, SQLERRM;
            END;
        END LOOP;
        
        RAISE NOTICE 'Column $x completed: % tiles generated', generated_count;
    END
    \$\$;
    " 2>&1)
    
    echo "$(date): Column $x result: $COLUMN_RESULT"
    
    # Check for errors
    if echo "$COLUMN_RESULT" | grep -q "ERROR"; then
        echo "$(date): ERROR in column $x: $COLUMN_RESULT"
        break
    fi
    
    PROCESSED=$((PROCESSED + 1))
    
    # Progress update every 50 columns
    if (( PROCESSED % 50 == 0 )); then
        PROGRESS=$((PROCESSED * 100 / 256))
        echo "$(date): Progress: $PROGRESS% ($PROCESSED/256 columns)"
    fi
done

# Show final statistics
echo "$(date): Synthetic global data generation complete!"

# Get actual counts from database
COUNTS=$(psql "$DATABASE_URL" -t -c "
SELECT 
    'Points: ' || COUNT(*) as points
FROM demo_points
UNION ALL
SELECT 
    'Lines: ' || COUNT(*) as lines  
FROM demo_lines
UNION ALL
SELECT 
    'Polygons: ' || COUNT(*) as polygons
FROM demo_polygons
UNION ALL
SELECT 
    'Total geometries: ' || (
        (SELECT COUNT(*) FROM demo_points) + 
        (SELECT COUNT(*) FROM demo_lines) + 
        (SELECT COUNT(*) FROM demo_polygons)
    ) as total;
" | tr -d ' ')

echo "$(date): Synthetic data created:"
echo "$COUNTS"

# Show global coverage
echo ""
echo "$(date): Global coverage verification:"
psql "$DATABASE_URL" -c "
WITH bounds AS (
    SELECT ST_Transform(ST_SetSRID(ST_Extent(geom), 3857), 4326) as bbox
    FROM (
        SELECT geom FROM demo_points
        UNION ALL
        SELECT geom FROM demo_lines  
        UNION ALL
        SELECT geom FROM demo_polygons
    ) all_geoms
)
SELECT 
    'Global Coverage:' as info,
    ROUND(ST_XMin(bbox)::numeric, 2) as min_lon,
    ROUND(ST_YMin(bbox)::numeric, 2) as min_lat, 
    ROUND(ST_XMax(bbox)::numeric, 2) as max_lon,
    ROUND(ST_YMax(bbox)::numeric, 2) as max_lat,
    ROUND((ST_XMax(bbox) - ST_XMin(bbox))::numeric, 1) as lon_span,
    ROUND((ST_YMax(bbox) - ST_YMin(bbox))::numeric, 1) as lat_span
FROM bounds;
"

# Check how many tiles have pending changes (should be many!)
PENDING_COUNT=$(psql "$DATABASE_URL" -t -c "
SELECT COUNT(DISTINCT (z, x, y)) 
FROM changed_tiles 
WHERE processed_at IS NULL;
" | tr -d ' ')

echo ""
echo "$(date): Pending tiles ready for processing: $PENDING_COUNT"
echo "$(date): Synthetic global demo data ready! 🌍"
echo ""
echo "Next steps:"
echo "  1. JVT worker will process tiles automatically every 5 minutes"
echo "  2. Use synthetic_change_simulator.sh to create ongoing changes"
echo "  3. Watch frontend for global tile freshness visualization"