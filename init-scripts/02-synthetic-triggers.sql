-- Change Detection Triggers for Synthetic Schema
-- Much simpler than OSM version - clean and focused

-- Generic change tracking function for all synthetic tables
CREATE OR REPLACE FUNCTION track_synthetic_changes() 
RETURNS TRIGGER AS $$
DECLARE
    geom_to_process geometry;
    table_name text;
    operation_type text;
    tiles_affected integer := 0;
BEGIN
    -- Get table name and operation type
    table_name := TG_TABLE_NAME;
    operation_type := TG_OP;
    
    -- Determine which geometry to process
    IF TG_OP = 'DELETE' THEN
        geom_to_process := OLD.geom;
    ELSE
        geom_to_process := NEW.geom;
    END IF;
    
    -- Only process if we have valid geometry
    IF geom_to_process IS NOT NULL THEN
        -- Insert affected tiles into changed_tiles table
        INSERT INTO changed_tiles (z, x, y, source_table, operation)
        SELECT t.z, t.x, t.y, table_name, operation_type
        FROM calculate_affected_tiles_synthetic(geom_to_process, 8, 8) t  -- Only z8 for demo
        WHERE NOT EXISTS (
            SELECT 1 FROM changed_tiles ct 
            WHERE ct.z = t.z AND ct.x = t.x AND ct.y = t.y 
            AND ct.processed_at IS NULL
        ); -- Avoid duplicates of unprocessed tiles
        
        -- Count how many tiles were affected
        GET DIAGNOSTICS tiles_affected = ROW_COUNT;
        
        -- Send simple notification that tiles have changed
        PERFORM pg_notify('tiles_updated', 
            json_build_object(
                'table', table_name,
                'operation', operation_type,
                'tile_count', tiles_affected,
                'timestamp', extract(epoch from now())
            )::text
        );
        
        -- Log the change for debugging
        RAISE DEBUG 'Synthetic change: % % affected % tiles', operation_type, table_name, tiles_affected;
    END IF;
    
    -- Return appropriate value based on operation
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Create triggers for all synthetic tables
-- Much cleaner than OSM - just 3 triggers instead of 4+!

DROP TRIGGER IF EXISTS demo_points_changes ON demo_points;
CREATE TRIGGER demo_points_changes
    AFTER INSERT OR UPDATE OR DELETE ON demo_points
    FOR EACH ROW EXECUTE FUNCTION track_synthetic_changes();

DROP TRIGGER IF EXISTS demo_lines_changes ON demo_lines;
CREATE TRIGGER demo_lines_changes
    AFTER INSERT OR UPDATE OR DELETE ON demo_lines
    FOR EACH ROW EXECUTE FUNCTION track_synthetic_changes();

DROP TRIGGER IF EXISTS demo_polygons_changes ON demo_polygons;
CREATE TRIGGER demo_polygons_changes
    AFTER INSERT OR UPDATE OR DELETE ON demo_polygons
    FOR EACH ROW EXECUTE FUNCTION track_synthetic_changes();

-- Helper function to clear old test data (useful for resetting demo)
CREATE OR REPLACE FUNCTION reset_synthetic_demo() 
RETURNS void AS $$
BEGIN
    -- Clear all synthetic data
    TRUNCATE TABLE demo_points CASCADE;
    TRUNCATE TABLE demo_lines CASCADE; 
    TRUNCATE TABLE demo_polygons CASCADE;
    TRUNCATE TABLE changed_tiles CASCADE;
    TRUNCATE TABLE changed_tile_batches CASCADE;
    
    -- Reset sequences
    ALTER SEQUENCE demo_points_id_seq RESTART WITH 1;
    ALTER SEQUENCE demo_lines_id_seq RESTART WITH 1;
    ALTER SEQUENCE demo_polygons_id_seq RESTART WITH 1;
    ALTER SEQUENCE changed_tiles_id_seq RESTART WITH 1;
    ALTER SEQUENCE changed_tile_batches_id_seq RESTART WITH 1;
    
    RAISE NOTICE 'Synthetic demo data reset complete';
END;
$$ LANGUAGE plpgsql;

-- Function to generate simple test geometry for a given tile
CREATE OR REPLACE FUNCTION generate_tile_test_data(
    tile_x integer,
    tile_y integer,
    tile_z integer DEFAULT 8,
    points_per_tile integer DEFAULT 2
) RETURNS void AS $$
DECLARE
    -- Tile bounds in Web Mercator
    tile_bounds geometry;
    center_point geometry;
    random_point geometry;
    random_line geometry;
    random_polygon geometry;
    i integer;
    inserted_points integer := 0;
    inserted_lines integer := 0;
    inserted_polygons integer := 0;
BEGIN
    -- Calculate tile bounds in Web Mercator (3857)
    BEGIN
        tile_bounds := ST_TileEnvelope(tile_z, tile_x, tile_y);
        center_point := ST_Centroid(tile_bounds);
        
        IF tile_bounds IS NULL OR center_point IS NULL THEN
            RAISE EXCEPTION 'Failed to calculate tile bounds for tile %,% at zoom %', tile_x, tile_y, tile_z;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE EXCEPTION 'Error calculating tile envelope: %', SQLERRM;
    END;
    
    -- Generate random points within the tile
    FOR i IN 1..points_per_tile LOOP
        BEGIN
            -- Use a simpler approach: random point within tile bounds
            random_point := ST_SetSRID(
                ST_MakePoint(
                    ST_XMin(tile_bounds) + random() * (ST_XMax(tile_bounds) - ST_XMin(tile_bounds)),
                    ST_YMin(tile_bounds) + random() * (ST_YMax(tile_bounds) - ST_YMin(tile_bounds))
                ), 
                3857
            );
            
            INSERT INTO demo_points (geom, demo_tag) 
            VALUES (random_point, format('tile_%s_%s_point_%s', tile_x, tile_y, i));
            inserted_points := inserted_points + 1;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE WARNING 'Failed to insert point % for tile %,%: %', i, tile_x, tile_y, SQLERRM;
        END;
    END LOOP;
    
    -- Generate a simple line across the tile
    BEGIN
        random_line := ST_MakeLine(
            ST_SetSRID(ST_MakePoint(ST_XMin(tile_bounds), ST_YMin(tile_bounds)), 3857),
            ST_SetSRID(ST_MakePoint(ST_XMax(tile_bounds), ST_YMax(tile_bounds)), 3857)
        );
        INSERT INTO demo_lines (geom, demo_tag) 
        VALUES (random_line, format('tile_%s_%s_line', tile_x, tile_y));
        inserted_lines := inserted_lines + 1;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE WARNING 'Failed to insert line for tile %,%: %', tile_x, tile_y, SQLERRM;
    END;
    
    -- Generate a simple polygon (small box within tile)
    BEGIN
        random_polygon := ST_Buffer(center_point, 
            LEAST(ST_XMax(tile_bounds) - ST_XMin(tile_bounds), 
                  ST_YMax(tile_bounds) - ST_YMin(tile_bounds)) * 0.1);
        INSERT INTO demo_polygons (geom, demo_tag) 
        VALUES (random_polygon, format('tile_%s_%s_polygon', tile_x, tile_y));
        inserted_polygons := inserted_polygons + 1;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE WARNING 'Failed to insert polygon for tile %,%: %', tile_x, tile_y, SQLERRM;
    END;
    
    -- Debug output for first few tiles
    IF tile_x < 2 AND tile_y < 52 THEN
        RAISE NOTICE 'Tile %,% generated: % points, % lines, % polygons', 
            tile_x, tile_y, inserted_points, inserted_lines, inserted_polygons;
    END IF;
    
END;
$$ LANGUAGE plpgsql;

-- Initialize notification channel
-- The Rust worker will LISTEN on this channel
LISTEN tiles_updated;