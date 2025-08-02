#!/bin/bash
# synthetic_change_simulator.sh - Simulate changes in synthetic demo data
# Much simpler than OSM approach - clean database operations

set -euo pipefail

DATABASE_URL="${DATABASE_URL:-postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/gis}"

echo "$(date): Starting synthetic change simulation..."

# Configuration for global sparse changes
CHANGES_PER_CYCLE=50       # 50 changes scattered globally (manageable)
ZOOM_LEVEL=8               # z8 tiles

# Simulate realistic change distribution
INSERT_PCT=60              # 60% inserts (new features)
UPDATE_PCT=30              # 30% updates (moved features)  
DELETE_PCT=10              # 10% deletes (removed features)

INSERT_COUNT=$((CHANGES_PER_CYCLE * INSERT_PCT / 100))
UPDATE_COUNT=$((CHANGES_PER_CYCLE * UPDATE_PCT / 100))
DELETE_COUNT=$((CHANGES_PER_CYCLE * DELETE_PCT / 100))

echo "$(date): Simulating $CHANGES_PER_CYCLE global changes (${INSERT_COUNT}I/${UPDATE_COUNT}U/${DELETE_COUNT}D)..."

INSERTS=0
UPDATES=0  
DELETES=0

# 1. GLOBAL INSERTS - Add new synthetic features
echo "$(date): Creating $INSERT_COUNT new synthetic features globally..."

# Execute the insert operations
psql "$DATABASE_URL" -c "
DO \$\$
DECLARE
    insert_count integer := 0;
    random_x integer;
    random_y integer;
    tile_bounds geometry;
    random_point geometry;
    feature_type integer;
BEGIN
    FOR i IN 1..$INSERT_COUNT LOOP
        -- Pick random tile coordinates (global coverage)
        random_x := floor(random() * 256)::integer;
        random_y := floor(random() * 216)::integer + 20;  -- Skip polar regions (y: 20-235)
        
        -- Get tile bounds  
        tile_bounds := ST_TileEnvelope($ZOOM_LEVEL, random_x, random_y);
        
        -- Generate random point within tile using simpler method
        random_point := ST_SetSRID(
            ST_MakePoint(
                ST_XMin(tile_bounds) + random() * (ST_XMax(tile_bounds) - ST_XMin(tile_bounds)),
                ST_YMin(tile_bounds) + random() * (ST_YMax(tile_bounds) - ST_YMin(tile_bounds))
            ), 
            3857
        );
        
        -- Randomly choose feature type (points are most common)
        feature_type := floor(random() * 10)::integer;
        
        IF feature_type < 7 THEN
            -- 70% points
            INSERT INTO demo_points (geom, demo_tag) 
            VALUES (random_point, 'global_change_' || extract(epoch from now())::bigint || '_' || i);
            insert_count := insert_count + 1;
            
        ELSIF feature_type < 9 THEN
            -- 20% lines  
            INSERT INTO demo_lines (geom, demo_tag) 
            VALUES (
                ST_MakeLine(
                    random_point, 
                    ST_SetSRID(
                        ST_MakePoint(
                            ST_XMin(tile_bounds) + random() * (ST_XMax(tile_bounds) - ST_XMin(tile_bounds)),
                            ST_YMin(tile_bounds) + random() * (ST_YMax(tile_bounds) - ST_YMin(tile_bounds))
                        ), 
                        3857
                    )
                ),
                'global_line_' || extract(epoch from now())::bigint || '_' || i
            );
            insert_count := insert_count + 1;
            
        ELSE
            -- 10% polygons
            INSERT INTO demo_polygons (geom, demo_tag) 
            VALUES (
                ST_Buffer(random_point, ST_Distance(random_point, ST_Centroid(tile_bounds)) * 0.1),
                'global_polygon_' || extract(epoch from now())::bigint || '_' || i
            );
            insert_count := insert_count + 1;
        END IF;
    END LOOP;
    
    RAISE NOTICE 'Inserted % synthetic features', insert_count;
END
\$\$;" > /dev/null 2>&1

# Get the actual count  
INSERTS=$(psql "$DATABASE_URL" -t -c "
SELECT COUNT(*) FROM demo_points WHERE demo_tag LIKE 'global_change_%' 
    AND created_at > NOW() - INTERVAL '10 seconds';
" | tr -d ' ')

# 2. GLOBAL UPDATES - Move existing features to new locations  
echo "$(date): Updating $UPDATE_COUNT existing synthetic features..."

# Execute the update operations
psql "$DATABASE_URL" -c "
DO \$\$
DECLARE
    update_count integer := 0;
    random_x integer;
    random_y integer;
    tile_bounds geometry;
    new_location geometry;
BEGIN
    -- Update random points
    FOR i IN 1..($UPDATE_COUNT / 2) LOOP
        random_x := floor(random() * 256)::integer;
        random_y := floor(random() * 216)::integer + 20;
        tile_bounds := ST_TileEnvelope($ZOOM_LEVEL, random_x, random_y);
        new_location := ST_SetSRID(
            ST_MakePoint(
                ST_XMin(tile_bounds) + random() * (ST_XMax(tile_bounds) - ST_XMin(tile_bounds)),
                ST_YMin(tile_bounds) + random() * (ST_YMax(tile_bounds) - ST_YMin(tile_bounds))
            ), 
            3857
        );
        
        UPDATE demo_points 
        SET geom = new_location, 
            updated_at = NOW(),
            demo_tag = demo_tag || '_moved'
        WHERE id IN (
            SELECT id FROM demo_points 
            WHERE demo_tag NOT LIKE '%_moved'
            ORDER BY random() 
            LIMIT 1
        );
        
        GET DIAGNOSTICS update_count = ROW_COUNT;
        IF update_count > 0 THEN
            EXIT;
        END IF;
    END LOOP;
    
    -- Update random lines  
    FOR i IN 1..($UPDATE_COUNT / 2) LOOP
        random_x := floor(random() * 256)::integer;
        random_y := floor(random() * 216)::integer + 20;
        tile_bounds := ST_TileEnvelope($ZOOM_LEVEL, random_x, random_y);
        
        UPDATE demo_lines 
        SET geom = ST_MakeLine(
                ST_SetSRID(
                    ST_MakePoint(
                        ST_XMin(tile_bounds) + random() * (ST_XMax(tile_bounds) - ST_XMin(tile_bounds)),
                        ST_YMin(tile_bounds) + random() * (ST_YMax(tile_bounds) - ST_YMin(tile_bounds))
                    ), 
                    3857
                ),
                ST_SetSRID(
                    ST_MakePoint(
                        ST_XMin(tile_bounds) + random() * (ST_XMax(tile_bounds) - ST_XMin(tile_bounds)),
                        ST_YMin(tile_bounds) + random() * (ST_YMax(tile_bounds) - ST_YMin(tile_bounds))
                    ), 
                    3857
                )
            ),
            updated_at = NOW(),
            demo_tag = demo_tag || '_moved'
        WHERE id IN (
            SELECT id FROM demo_lines
            WHERE demo_tag NOT LIKE '%_moved' 
            ORDER BY random()
            LIMIT 1
        );
        
        GET DIAGNOSTICS update_count = ROW_COUNT;
        IF update_count > 0 THEN
            EXIT;
        END IF;
    END LOOP;
END
\$\$;" > /dev/null 2>&1

# Get the actual update count
UPDATES=$(psql "$DATABASE_URL" -t -c "
SELECT COUNT(*) FROM (
    SELECT 1 FROM demo_points WHERE demo_tag LIKE '%_moved' AND updated_at > NOW() - INTERVAL '10 seconds'
    UNION ALL
    SELECT 1 FROM demo_lines WHERE demo_tag LIKE '%_moved' AND updated_at > NOW() - INTERVAL '10 seconds'
) updated_features;
" | tr -d ' ')

# 3. GLOBAL DELETES - Remove some existing features
echo "$(date): Removing $DELETE_COUNT synthetic features..."

DELETES=$(psql "$DATABASE_URL" -t -c "
WITH deleted_points AS (
    DELETE FROM demo_points 
    WHERE id IN (
        SELECT id FROM demo_points 
        WHERE demo_tag NOT LIKE 'tile_%'  -- Don't delete core tile data
        ORDER BY random() 
        LIMIT ($DELETE_COUNT / 2)
    )
    RETURNING id
),
deleted_lines AS (
    DELETE FROM demo_lines 
    WHERE id IN (
        SELECT id FROM demo_lines 
        WHERE demo_tag NOT LIKE 'tile_%'  -- Don't delete core tile data
        ORDER BY random() 
        LIMIT ($DELETE_COUNT / 2)
    )
    RETURNING id
)
SELECT (SELECT COUNT(*) FROM deleted_points) + (SELECT COUNT(*) FROM deleted_lines);
" | tr -d ' ')

# Show simulation results
echo ""
echo "$(date): SYNTHETIC CHANGE SUMMARY:"
echo "  Inserts: $INSERTS / $INSERT_COUNT (new features added globally)"
echo "  Updates: $UPDATES / $UPDATE_COUNT (features moved between tiles)"  
echo "  Deletes: $DELETES / $DELETE_COUNT (features removed globally)"
echo "  Total changes: $((INSERTS + UPDATES + DELETES))"

# Show pending tiles globally
PENDING_COUNT=$(psql "$DATABASE_URL" -t -c "
SELECT COUNT(DISTINCT (z, x, y))
FROM changed_tiles 
WHERE processed_at IS NULL;
" | tr -d ' ')

echo "  Pending tiles globally: $PENDING_COUNT"

# Show current synthetic data totals
echo ""
echo "$(date): Current synthetic data totals:"
psql "$DATABASE_URL" -c "
SELECT 
    'Points' as feature_type,
    COUNT(*) as total_count,
    COUNT(*) FILTER (WHERE created_at > NOW() - INTERVAL '1 hour') as recent_count
FROM demo_points
UNION ALL
SELECT 
    'Lines' as feature_type,
    COUNT(*) as total_count,
    COUNT(*) FILTER (WHERE created_at > NOW() - INTERVAL '1 hour') as recent_count
FROM demo_lines
UNION ALL  
SELECT 
    'Polygons' as feature_type,
    COUNT(*) as total_count,
    COUNT(*) FILTER (WHERE created_at > NOW() - INTERVAL '1 hour') as recent_count
FROM demo_polygons
ORDER BY feature_type;
"

echo ""
echo "$(date): Synthetic change simulation complete - global tiles affected! 🌍"