/***********************************************************************
  01-synthetic-schema.sql
  ----------------------------------------------------------------------
  Minimal schema for the JVT synthetic demo.
***********************************************************************/

-----------------------------
--  Enable PostGIS
-----------------------------
CREATE EXTENSION IF NOT EXISTS postgis;

-----------------------------
--  Geometry tables
-----------------------------
CREATE TABLE IF NOT EXISTS demo_points (
    id         BIGSERIAL PRIMARY KEY,
    geom       GEOMETRY(Point, 3857) NOT NULL,
    demo_tag   TEXT DEFAULT 'demo_point',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS demo_lines (
    id         BIGSERIAL PRIMARY KEY,
    geom       GEOMETRY(LineString, 3857) NOT NULL,
    demo_tag   TEXT DEFAULT 'demo_line',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS demo_polygons (
    id         BIGSERIAL PRIMARY KEY,
    geom       GEOMETRY(Polygon, 3857) NOT NULL,
    demo_tag   TEXT DEFAULT 'demo_polygon',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Spatial indexes
CREATE INDEX IF NOT EXISTS idx_demo_points_geom   ON demo_points   USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_demo_lines_geom    ON demo_lines    USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_demo_polygons_geom ON demo_polygons USING GIST (geom);

-----------------------------
--  Tile-change queue
-----------------------------
CREATE TABLE IF NOT EXISTS changed_tiles (
    id           BIGSERIAL  PRIMARY KEY,
    z            INT        NOT NULL,
    x            INT        NOT NULL,
    y            INT        NOT NULL,
    source_table TEXT       NOT NULL,
    operation    TEXT       NOT NULL,       -- INSERT | UPDATE | DELETE
    changed_at   TIMESTAMPTZ DEFAULT NOW(),
    processed_at TIMESTAMPTZ
);

-- **Single authoritative index – guarantees 1 row per tile**
-- Drop existing index if it exists with wrong data type
DROP INDEX IF EXISTS changed_tiles_zxy_unique;

CREATE UNIQUE INDEX IF NOT EXISTS changed_tiles_zxy_unique
ON changed_tiles (z, x, y);

-- Partial index for the worker’s queue scan
CREATE INDEX IF NOT EXISTS idx_changed_tiles_unprocessed
ON changed_tiles (changed_at)
WHERE processed_at IS NULL;

-----------------------------
--  Batch bookkeeping (unchanged)
-----------------------------
CREATE TABLE IF NOT EXISTS changed_tile_batches (
    id         BIGSERIAL PRIMARY KEY,
    first_z    INT,
    last_z     INT,
    tile_count INT,
    started_at TIMESTAMPTZ,
    finished_at TIMESTAMPTZ,
    source_type TEXT DEFAULT 'synthetic_demo'
);

CREATE INDEX IF NOT EXISTS idx_changed_tile_batches_started_at
ON changed_tile_batches (started_at);

-----------------------------
--  Helper: calculate tiles hit by a geometry
-----------------------------
CREATE OR REPLACE FUNCTION calculate_affected_tiles_synthetic(
    geom      GEOMETRY,
    min_zoom  INT,
    max_zoom  INT
)
RETURNS TABLE (z INT, x INT, y INT)
LANGUAGE plpgsql AS $$
DECLARE
    zoom_level INT;
    bounds     GEOMETRY;
    lon_min    FLOAT8;
    lon_max    FLOAT8;
    lat_min    FLOAT8;
    lat_max    FLOAT8;
    x_min      INT;
    x_max      INT;
    y_min      INT;
    y_max      INT;
    n          INT;
BEGIN
    bounds := ST_Transform(ST_Envelope(geom), 4326);

    FOR zoom_level IN min_zoom .. max_zoom LOOP
        lon_min := ST_XMin(bounds);
        lon_max := ST_XMax(bounds);
        lat_min := ST_YMin(bounds);
        lat_max := ST_YMax(bounds);

        n := 2 ^ zoom_level;

        x_min := GREATEST(0,
                 LEAST(n-1, floor((lon_min + 180) / 360 * n)::INT));
        x_max := GREATEST(0,
                 LEAST(n-1, floor((lon_max + 180) / 360 * n)::INT));

        y_min := GREATEST(0,
                 LEAST(n-1, floor((1 - ln(tan(radians(lat_max))
                          + 1/cos(radians(lat_max))) / pi()) / 2 * n)::INT));
        y_max := GREATEST(0,
                 LEAST(n-1, floor((1 - ln(tan(radians(lat_min))
                          + 1/cos(radians(lat_min))) / pi()) / 2 * n)::INT));

        FOR x_idx IN x_min .. x_max LOOP
            FOR y_idx IN y_min .. y_max LOOP
                z := zoom_level;
                x := x_idx;
                y := y_idx;
                RETURN NEXT;
            END LOOP;
        END LOOP;
    END LOOP;
END;
$$;

-----------------------------
--  Helper: fetch pending tiles in batches
-----------------------------
CREATE OR REPLACE FUNCTION get_pending_tiles(batch_limit INT DEFAULT 1000)
RETURNS TABLE (z INT, x INT, y INT, count BIGINT)
LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    SELECT  ct.z,
            ct.x,
            ct.y,
            COUNT(*) AS count
    FROM   changed_tiles ct
    WHERE  ct.processed_at IS NULL
    GROUP  BY ct.z, ct.x, ct.y
    ORDER  BY MIN(ct.changed_at)
    LIMIT  batch_limit;
END;
$$;

-- Create the function that the Rust code is actually calling
CREATE OR REPLACE FUNCTION get_simulation_pending_tiles(batch_limit INT DEFAULT 1000)
RETURNS TABLE (z INT, x INT, y INT, count BIGINT)
LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    SELECT  ct.z,
            ct.x,
            ct.y,
            COUNT(*) AS count
    FROM   changed_tiles ct
    WHERE  ct.processed_at IS NULL
    GROUP  BY ct.z, ct.x, ct.y
    ORDER  BY MIN(ct.changed_at)
    LIMIT  batch_limit;
END;
$$;

-----------------------------
--  Demo-friendly config tweaks
-----------------------------
ALTER SYSTEM SET autovacuum          = ON;
ALTER SYSTEM SET work_mem            = '64MB';
ALTER SYSTEM SET shared_buffers      = '512MB';
ALTER SYSTEM SET effective_cache_size = '1GB';

-- Reload
SELECT pg_reload_conf();

-----------------------------
--  Data type migration
-----------------------------
-- Fix data types if tables already exist
DO $$
BEGIN
    -- Fix changed_tiles.z from SMALLINT to INT
    IF EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'changed_tiles' 
        AND column_name = 'z' 
        AND data_type = 'smallint'
    ) THEN
        ALTER TABLE changed_tiles ALTER COLUMN z TYPE INT;
        RAISE NOTICE 'Updated changed_tiles.z from SMALLINT to INT';
    END IF;
    
    -- Fix changed_tile_batches.first_z from SMALLINT to INT
    IF EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'changed_tile_batches' 
        AND column_name = 'first_z' 
        AND data_type = 'smallint'
    ) THEN
        ALTER TABLE changed_tile_batches ALTER COLUMN first_z TYPE INT;
        ALTER TABLE changed_tile_batches ALTER COLUMN last_z TYPE INT;
        RAISE NOTICE 'Updated changed_tile_batches z columns from SMALLINT to INT';
    END IF;
END;
$$;
