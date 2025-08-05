/***********************************************************************
  03-initial-data.sql
  ----------------------------------------------------------------------
  Fast baseline loader for the JVT demo.
  • Populates every z8 tile (65 536 tiles) with:
      – 2 points
      – 1 line
      – 1 polygon
  • Disables triggers while loading for speed;
    re-enables them afterwards.
  • Seeds changed_tiles in one set-based INSERT so the worker still
    sees the initial 65 536 pending tiles.
***********************************************************************/

-----------------------------
--  1.  Reset any old data
-----------------------------
SELECT reset_synthetic_demo();

-----------------------------
--  2.  Disable triggers
-----------------------------
SET session_replication_role = replica;   -- skips all AFTER INSERT triggers

-----------------------------
--  3.  Pre-compute per-tile geometry
-----------------------------
WITH tiles AS (
    SELECT
        x,
        y,
        ST_TileEnvelope(8, x, y)        AS env,
        ST_Centroid( ST_TileEnvelope(8,x,y) ) AS ctr
    FROM generate_series(0,255) AS x
    CROSS JOIN generate_series(0,255) AS y
),

---------------------------------
--  3a.  Insert 2 points / tile
---------------------------------
points AS (
    INSERT INTO demo_points (geom, demo_tag)
    SELECT
        ST_SetSRID(
            ST_MakePoint(
                ST_XMin(env) + random() * (ST_XMax(env)-ST_XMin(env)),
                ST_YMin(env) + random() * (ST_YMax(env)-ST_YMin(env))
            ), 3857
        ),
        format('tile_%s_%s_point_%s', x, y, p)
    FROM tiles
    CROSS JOIN generate_series(1,2) AS p
    RETURNING 1
),

---------------------------------
--  3b.  Insert 1 line   / tile
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
    RETURNING 1
),

---------------------------------
--  3c.  Insert 1 polygon / tile
---------------------------------
polys AS (
    INSERT INTO demo_polygons (geom, demo_tag)
    SELECT
        ST_Buffer(ctr, 180),              -- 180 m radius (stays in tile)
        format('tile_%s_%s_polygon', x, y)
    FROM tiles
    RETURNING 1
)
SELECT  -- progress notice
    'Baseline data inserted: '
    || (SELECT COUNT(*) FROM points)
    + (SELECT COUNT(*) FROM lines)
    + (SELECT COUNT(*) FROM polys)
    || ' geometries' AS info;

-----------------------------
--  4.  Re-enable triggers
-----------------------------
SET session_replication_role = DEFAULT;

-----------------------------
--  5.  No initial tile seeding
--      (tiles will be generated on-demand via user simulation)
-----------------------------
-- Removed: Initial seeding of all tiles to allow clean startup

-----------------------------
--  6.  Completion marker
-----------------------------
CREATE TABLE IF NOT EXISTS initial_data_complete (
    completed_at     TIMESTAMPTZ DEFAULT NOW(),
    total_geometries INTEGER,
    total_tiles      INTEGER
);

INSERT INTO initial_data_complete (total_geometries, total_tiles)
SELECT
    (SELECT COUNT(*) FROM demo_points)
  + (SELECT COUNT(*) FROM demo_lines)
  + (SELECT COUNT(*) FROM demo_polygons),
    256*256;

-----------------------------
--  7.  Final summary
-----------------------------
SELECT
    'Initial Data Summary:'                 AS info,
    (SELECT COUNT(*) FROM demo_points)      AS points,
    (SELECT COUNT(*) FROM demo_lines)       AS lines,
    (SELECT COUNT(*) FROM demo_polygons)    AS polygons,
    (SELECT COUNT(*) FROM changed_tiles
      WHERE processed_at IS NULL)           AS pending_tiles;
