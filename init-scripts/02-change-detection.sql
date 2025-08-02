-- Change Detection System for JVT
-- Works with any PostGIS table containing geometries

-- Table to track tiles that need regeneration
CREATE TABLE IF NOT EXISTS changed_tiles (
    id BIGSERIAL PRIMARY KEY,
    z INTEGER NOT NULL,
    x INTEGER NOT NULL, 
    y INTEGER NOT NULL,
    changed_at TIMESTAMPTZ DEFAULT NOW(),
    processed_at TIMESTAMPTZ NULL,
    -- Track what caused the change for debugging
    source_table TEXT,
    operation TEXT, -- INSERT, UPDATE, DELETE
    
    -- Note: Unique constraint on unprocessed tiles is created as a partial index below
);

-- Indexes for efficient querying
CREATE INDEX IF NOT EXISTS idx_changed_tiles_unprocessed 
ON changed_tiles(changed_at) WHERE processed_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_changed_tiles_zxy 
ON changed_tiles(z, x, y);

-- Unique constraint: only one unprocessed tile per coordinate (prevents duplicates)
CREATE UNIQUE INDEX IF NOT EXISTS changed_tiles_z_x_y_unprocessed_unique 
ON changed_tiles(z, x, y) 
WHERE processed_at IS NULL;

-- Function to calculate which tiles are affected by a geometry change
CREATE OR REPLACE FUNCTION calculate_affected_tiles(
    geom geometry,
    min_zoom integer DEFAULT 8,
    max_zoom integer DEFAULT 14
) RETURNS TABLE(z integer, x integer, y integer) AS $$
DECLARE
    bounds geometry;
    zoom_level integer;
    min_x integer;
    max_x integer;
    min_y integer;
    max_y integer;
    x_coord integer;
    y_coord integer;
BEGIN
    -- Get the bounding box of the geometry in WGS84 (required for tile calculations)
    bounds := ST_Envelope(ST_Transform(geom, 4326));
    
    -- For each zoom level, calculate affected tiles
    FOR zoom_level IN min_zoom..max_zoom LOOP
        -- Calculate tile bounds at this zoom level
        -- Tile coordinate math: https://wiki.openstreetmap.org/wiki/Slippy_map_tilenames
        
        min_x := floor((ST_XMin(bounds) + 180.0) / 360.0 * (1 << zoom_level));
        max_x := floor((ST_XMax(bounds) + 180.0) / 360.0 * (1 << zoom_level));
        
        min_y := floor((1.0 - ln(tan(radians(ST_YMax(bounds))) + 1.0 / cos(radians(ST_YMax(bounds)))) / pi()) / 2.0 * (1 << zoom_level));
        max_y := floor((1.0 - ln(tan(radians(ST_YMin(bounds))) + 1.0 / cos(radians(ST_YMin(bounds)))) / pi()) / 2.0 * (1 << zoom_level));
        
        -- Ensure bounds are valid
        min_x := GREATEST(0, min_x);
        max_x := LEAST((1 << zoom_level) - 1, max_x);
        min_y := GREATEST(0, min_y);
        max_y := LEAST((1 << zoom_level) - 1, max_y);
        
        -- Return all affected tiles
        FOR x_coord IN min_x..max_x LOOP
            FOR y_coord IN min_y..max_y LOOP
                z := zoom_level;
                x := x_coord;
                y := y_coord;
                RETURN NEXT;
            END LOOP;
        END LOOP;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Generic trigger function for any geometry table
CREATE OR REPLACE FUNCTION track_geometry_changes() 
RETURNS TRIGGER AS $$
DECLARE
    geom_to_process geometry;
    table_name text;
    operation_type text;
BEGIN
    -- Get table name and operation type
    table_name := TG_TABLE_NAME;
    operation_type := TG_OP;
    
    -- Determine which geometry to process
    IF TG_OP = 'DELETE' THEN
        geom_to_process := OLD.way; -- OSM tables use 'way' column
        IF geom_to_process IS NULL THEN
            geom_to_process := OLD.geom; -- Generic 'geom' column
        END IF;
    ELSE
        geom_to_process := NEW.way;
        IF geom_to_process IS NULL THEN
            geom_to_process := NEW.geom;
        END IF;
    END IF;
    
    -- Only process if we found a geometry
    IF geom_to_process IS NOT NULL THEN
        -- Insert affected tiles into changed_tiles table
        INSERT INTO changed_tiles (z, x, y, source_table, operation)
        SELECT t.z, t.x, t.y, table_name, operation_type
        FROM calculate_affected_tiles(geom_to_process) t
        WHERE NOT EXISTS (
            SELECT 1 FROM changed_tiles ct 
            WHERE ct.z = t.z AND ct.x = t.x AND ct.y = t.y 
            AND ct.processed_at IS NULL
        ); -- Avoid duplicates of unprocessed tiles
        
        -- Send notification that tiles have changed
        PERFORM pg_notify('tiles_updated', 
            json_build_object(
                'table', table_name,
                'operation', operation_type,
                'tile_count', (SELECT count(*) FROM calculate_affected_tiles(geom_to_process))
            )::text
        );
    END IF;
    
    -- Return appropriate record
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Apply triggers to OSM tables (we'll make this more generic later)
CREATE TRIGGER planet_osm_point_changes
    AFTER INSERT OR UPDATE OR DELETE ON planet_osm_point
    FOR EACH ROW EXECUTE FUNCTION track_geometry_changes();

CREATE TRIGGER planet_osm_line_changes
    AFTER INSERT OR UPDATE OR DELETE ON planet_osm_line
    FOR EACH ROW EXECUTE FUNCTION track_geometry_changes();

CREATE TRIGGER planet_osm_polygon_changes
    AFTER INSERT OR UPDATE OR DELETE ON planet_osm_polygon
    FOR EACH ROW EXECUTE FUNCTION track_geometry_changes();

CREATE TRIGGER planet_osm_roads_changes
    AFTER INSERT OR UPDATE OR DELETE ON planet_osm_roads
    FOR EACH ROW EXECUTE FUNCTION track_geometry_changes();

-- Helper function to get pending tile changes with limit
CREATE OR REPLACE FUNCTION get_pending_tiles(batch_limit integer DEFAULT 1000)
RETURNS TABLE(z integer, x integer, y integer, count bigint) AS $$
BEGIN
    RETURN QUERY
    SELECT ct.z, ct.x, ct.y, count(*) as change_count
    FROM changed_tiles ct
    WHERE ct.processed_at IS NULL
    GROUP BY ct.z, ct.x, ct.y
    ORDER BY count(*) DESC, ct.z, ct.x, ct.y  -- Process highest-change tiles first
    LIMIT batch_limit;
END;
$$ LANGUAGE plpgsql;

-- Helper function to mark tiles as processed
CREATE OR REPLACE FUNCTION mark_tiles_processed(
    tile_coords json[]
) RETURNS integer AS $$
DECLARE
    updated_count integer;
    coord json;
BEGIN
    updated_count := 0;
    
    FOREACH coord IN ARRAY tile_coords LOOP
        UPDATE changed_tiles 
        SET processed_at = NOW()
        WHERE z = (coord->>'z')::integer
          AND x = (coord->>'x')::integer  
          AND y = (coord->>'y')::integer
          AND processed_at IS NULL;
        
        updated_count := updated_count + ROW_COUNT;
    END LOOP;
    
    RETURN updated_count;
END;
$$ LANGUAGE plpgsql;