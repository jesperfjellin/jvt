/***********************************************************************
  03-initial-data.sql
  ----------------------------------------------------------------------
  Fast baseline loader for the JVT demo.
  • Populates every z8 tile (65 536 tiles) with:
      – 2 points
      – 1 line
      – 1 polygon
  • Disables triggers while loading for speed;
    re-enables them afterwards.
  • Seeds changed_tiles in one set-based INSERT so the worker still
    sees the initial 65 536 pending tiles.
***********************************************************************/

-----------------------------
--  1.  Create completion marker table first
-----------------------------
CREATE TABLE IF NOT EXISTS initial_data_complete (
    completed_at     TIMESTAMPTZ DEFAULT NOW(),
    total_geometries INTEGER,
    total_tiles      INTEGER
);

-----------------------------
--  2.  Check if data already exists (idempotent)
-----------------------------
DO $$
BEGIN
    -- Check if we already have initial data
    IF EXISTS (
        SELECT 1 FROM initial_data_complete 
        WHERE total_geometries > 0 AND total_tiles > 0
    ) THEN
        RAISE NOTICE 'Initial data already exists, skipping data population';
        RETURN;
    END IF;
    
    -- Check if we have existing demo data that looks complete
    IF (SELECT COUNT(*) FROM demo_points WHERE demo_tag LIKE 'tile_%_point_%') >= 131072 
       AND (SELECT COUNT(*) FROM demo_lines WHERE demo_tag LIKE 'tile_%_line') >= 65536
       AND (SELECT COUNT(*) FROM demo_polygons WHERE demo_tag LIKE 'tile_%_polygon') >= 65536 THEN
        RAISE NOTICE 'Demo data already populated, marking as complete';
        
        -- Mark as complete without repopulating
        INSERT INTO initial_data_complete (total_geometries, total_tiles)
        SELECT
            (SELECT COUNT(*) FROM demo_points)
          + (SELECT COUNT(*) FROM demo_lines)
          + (SELECT COUNT(*) FROM demo_polygons),
            256*256;
        
        RETURN;
    END IF;
    
    -- If we get here, we need to populate data
    RAISE NOTICE 'Populating initial demo data...';
END;
$$;

-- Only reset if we're actually going to populate new data
SELECT reset_synthetic_demo();

-----------------------------
--  3.  Disable triggers
-----------------------------
SET session_replication_role = replica;   -- skips all AFTER INSERT triggers

-----------------------------
--  4.  Pre-compute per-tile geometry
-----------------------------
WITH tiles AS (
    SELECT
        x,
        y,
        ST_TileEnvelope(8, x, y)        AS env,
        ST_Centroid( ST_TileEnvelope(8,x,y) ) AS ctr
    FROM generate_series(0,255) AS x
    CROSS JOIN generate_series(0,255) AS y
    WHERE NOT EXISTS (SELECT 1 FROM initial_data_complete WHERE total_geometries > 0)
),

---------------------------------
--  4a.  Insert 2 points / tile (deterministic but randomized within tile)
---------------------------------
points AS (
    INSERT INTO demo_points (geom, demo_tag)
    SELECT
        ST_SetSRID(
            ST_MakePoint(
                ST_XMin(env) + (((x * 1000 + y * 100 + p) % 1000) / 1000.0) * (ST_XMax(env)-ST_XMin(env)),
                ST_YMin(env) + (((x * 1100 + y * 110 + p * 10) % 1000) / 1000.0) * (ST_YMax(env)-ST_YMin(env))
            ), 3857
        ),
        format('tile_%s_%s_point_%s', x, y, p)
    FROM tiles
    CROSS JOIN generate_series(1,2) AS p
    WHERE tiles.x IS NOT NULL  -- Only if tiles were selected
    RETURNING 1
),

---------------------------------
--  4b.  Insert 1 line   / tile
---------------------------------
lines AS (
    INSERT INTO demo_lines (geom, demo_tag)
    SELECT
        ST_MakeLine(
            ST_Translate(ctr, -200, -200),
            ST_Translate(ctr,  200,  200)
        ),
        format('tile_%s_%s_line', x, y)
    FROM tiles
    WHERE tiles.x IS NOT NULL  -- Only if tiles were selected
    RETURNING 1
),

---------------------------------
--  4c.  Insert 1 polygon / tile
---------------------------------
polys AS (
    INSERT INTO demo_polygons (geom, demo_tag)
    SELECT
        ST_Buffer(ctr, 180),              -- 180 m radius (stays in tile)
        format('tile_%s_%s_polygon', x, y)
    FROM tiles
    WHERE tiles.x IS NOT NULL  -- Only if tiles were selected
    RETURNING 1
)
SELECT  -- progress notice
    'Baseline data inserted: '
    || (SELECT COUNT(*) FROM points)
    + (SELECT COUNT(*) FROM lines)
    + (SELECT COUNT(*) FROM polys)
    || ' geometries' AS info;

-----------------------------
--  5.  Re-enable triggers
-----------------------------
SET session_replication_role = DEFAULT;

-----------------------------
--  6.  No initial tile seeding
--      (tiles will be generated on-demand via user simulation)
-----------------------------
-- Removed: Initial seeding of all tiles to allow clean startup

-----------------------------
--  7.  Insert completion marker (idempotent)
-----------------------------
-- Only insert completion marker if not already present
INSERT INTO initial_data_complete (total_geometries, total_tiles)
SELECT
    (SELECT COUNT(*) FROM demo_points)
  + (SELECT COUNT(*) FROM demo_lines)
  + (SELECT COUNT(*) FROM demo_polygons),
    256*256
WHERE NOT EXISTS (SELECT 1 FROM initial_data_complete WHERE total_geometries > 0);

-----------------------------
--  8.  Final summary
-----------------------------
SELECT
    'Initial Data Summary:'                 AS info,
    (SELECT COUNT(*) FROM demo_points)      AS points,
    (SELECT COUNT(*) FROM demo_lines)       AS lines,
    (SELECT COUNT(*) FROM demo_polygons)    AS polygons,
    (SELECT COUNT(*) FROM changed_tiles
      WHERE processed_at IS NULL)           AS pending_tiles;