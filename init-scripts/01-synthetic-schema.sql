-- Synthetic Schema for JVT Demo
-- Simple, clean tables designed specifically for tile demonstration

-- Enable PostGIS extension
CREATE EXTENSION IF NOT EXISTS postgis;

-- Simple demo geometry tables (much cleaner than OSM!)
CREATE TABLE IF NOT EXISTS demo_points (
    id BIGSERIAL PRIMARY KEY,
    geom GEOMETRY(Point, 3857) NOT NULL,  -- Web Mercator
    demo_tag TEXT DEFAULT 'demo_point',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS demo_lines (
    id BIGSERIAL PRIMARY KEY,
    geom GEOMETRY(LineString, 3857) NOT NULL,  -- Web Mercator
    demo_tag TEXT DEFAULT 'demo_line',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS demo_polygons (
    id BIGSERIAL PRIMARY KEY,
    geom GEOMETRY(Polygon, 3857) NOT NULL,  -- Web Mercator
    demo_tag TEXT DEFAULT 'demo_polygon',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Spatial indexes for performance
CREATE INDEX IF NOT EXISTS idx_demo_points_geom ON demo_points USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_demo_lines_geom ON demo_lines USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_demo_polygons_geom ON demo_polygons USING GIST (geom);

-- Tile change tracking (same as before, but simpler)
CREATE TABLE IF NOT EXISTS changed_tiles (
    id BIGSERIAL PRIMARY KEY,
    z SMALLINT NOT NULL,
    x INTEGER NOT NULL,
    y INTEGER NOT NULL,
    source_table TEXT NOT NULL,
    operation TEXT NOT NULL, -- INSERT, UPDATE, DELETE
    changed_at TIMESTAMPTZ DEFAULT NOW(),
    processed_at TIMESTAMPTZ NULL
);

-- Indexes for efficient tile processing
CREATE INDEX IF NOT EXISTS idx_changed_tiles_unprocessed 
ON changed_tiles(changed_at) WHERE processed_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_changed_tiles_zxy 
ON changed_tiles(z, x, y);

-- Prevent duplicate unprocessed tiles
CREATE UNIQUE INDEX IF NOT EXISTS changed_tiles_z_x_y_unprocessed_unique 
ON changed_tiles(z, x, y) WHERE processed_at IS NULL;

-- Batch tracking for statistics
CREATE TABLE IF NOT EXISTS changed_tile_batches (
    id BIGSERIAL PRIMARY KEY,
    first_z SMALLINT,
    last_z SMALLINT, 
    tile_count INTEGER,
    started_at TIMESTAMPTZ,
    finished_at TIMESTAMPTZ,
    source_type TEXT DEFAULT 'synthetic_demo'
);

-- Index for efficient batch querying
CREATE INDEX IF NOT EXISTS idx_changed_tile_batches_started_at 
ON changed_tile_batches(started_at);

-- Simple tile coordinate calculation function (much simpler than OSM!)
CREATE OR REPLACE FUNCTION calculate_affected_tiles_synthetic(
    geom geometry,
    min_zoom integer,
    max_zoom integer
) RETURNS TABLE(z integer, x integer, y integer) AS $$
DECLARE
    zoom_level integer;
    bounds geometry;
    lon_min float;
    lon_max float; 
    lat_min float;
    lat_max float;
    x_min integer;
    x_max integer;
    y_min integer;
    y_max integer;
    n integer;
BEGIN
    -- Transform to WGS84 for tile calculation
    bounds := ST_Transform(ST_Envelope(geom), 4326);
    
    FOR zoom_level IN min_zoom..max_zoom LOOP
        -- Get bounds in WGS84
        lon_min := ST_XMin(bounds);
        lon_max := ST_XMax(bounds);
        lat_min := ST_YMin(bounds);
        lat_max := ST_YMax(bounds);
        
        -- Calculate tile coordinates
        n := 2^zoom_level;
        
        x_min := GREATEST(0, LEAST(n-1, floor((lon_min + 180.0) / 360.0 * n)::integer));
        x_max := GREATEST(0, LEAST(n-1, floor((lon_max + 180.0) / 360.0 * n)::integer));
        
        y_min := GREATEST(0, LEAST(n-1, floor((1.0 - ln(tan(radians(lat_max)) + 1.0/cos(radians(lat_max))) / pi()) / 2.0 * n)::integer));
        y_max := GREATEST(0, LEAST(n-1, floor((1.0 - ln(tan(radians(lat_min)) + 1.0/cos(radians(lat_min))) / pi()) / 2.0 * n)::integer));
        
        -- Return all tiles in the bounding box
        FOR tile_x IN x_min..x_max LOOP
            FOR tile_y IN y_min..y_max LOOP
                z := zoom_level;
                x := tile_x;
                y := tile_y;
                RETURN NEXT;
            END LOOP;
        END LOOP;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Helper function to get pending tiles (simpler than OSM version)
CREATE OR REPLACE FUNCTION get_pending_tiles(batch_limit integer DEFAULT 1000)
RETURNS TABLE(z integer, x integer, y integer, count bigint) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        ct.z,
        ct.x, 
        ct.y,
        COUNT(*) as count
    FROM changed_tiles ct
    WHERE ct.processed_at IS NULL
    GROUP BY ct.z, ct.x, ct.y
    ORDER BY MIN(ct.changed_at)
    LIMIT batch_limit;
END;
$$ LANGUAGE plpgsql;

-- Optimize PostgreSQL for demo workload
ALTER SYSTEM SET autovacuum = on;
ALTER SYSTEM SET work_mem = '64MB';
ALTER SYSTEM SET shared_buffers = '512MB';
ALTER SYSTEM SET effective_cache_size = '1GB';

-- Reload configuration
SELECT pg_reload_conf();