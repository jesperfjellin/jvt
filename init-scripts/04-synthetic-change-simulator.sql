/***********************************************************************
  04-synthetic-change-simulator.sql
  ----------------------------------------------------------------------
  Real-time 5 % change simulator for JVT demo.

  • pick_tiles_for_tick()  – picks ≈ pct of z-level tiles using a simple
    modulo rule that is uniform, deterministic, and overflow-safe.
  • simulate_changes_5min() – applies local INSERT / DELETE / UPDATE
    operations inside the selected tiles.
  • Helper/test functions at the end.
***********************************************************************/

-----------------------------------------------------------------------
--  Helper: pick_tiles_for_tick()
--  --------------------------------
--  Selects ≈ pct of the tiles at zoom z.
--  Algorithm: linearised tile index (x*n + y) + epoch, modulo step.
--  step = floor(1/pct)   →   1 tile out of every “step” is chosen.
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pick_tiles_for_tick(
    z   INT,          -- zoom level (only 8 used in demo)
    pct FLOAT8        -- fraction to pick (e.g. 0.05 = 5 %)
)
RETURNS TABLE (x INT, y INT)
LANGUAGE sql AS $$
    WITH
    n      AS (SELECT 1 << z AS n),                 -- tiles per side
    epoch  AS (
        -- One bucket every 300 s (5 min); keeps selection moving
        SELECT floor(extract(epoch FROM now()) / 300)::INT AS e
    ),
    step   AS (
        -- e.g. pct = 0.05 → step = 20
        SELECT GREATEST(1, floor(1.0 / pct))::INT AS s
    )
    SELECT gx, gy
    FROM   n, epoch, step,
           generate_series(0, (SELECT n-1 FROM n)) AS gx,   -- x
           generate_series(0, (SELECT n-1 FROM n)) AS gy    -- y
    WHERE  ((gx * (SELECT n FROM n) + gy + (SELECT e FROM epoch))
            % (SELECT s FROM step)) = 0;
$$;

-----------------------------------------------------------------------
--  Main 5-minute change simulator
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION simulate_changes_5min(
    z   INT    DEFAULT 8,
    pct FLOAT8 DEFAULT 0.05
)
RETURNS TABLE (
    selected_tiles    INT,
    points_deleted    INT,
    points_inserted   INT,
    lines_updated     INT,
    polygons_updated  INT
)
LANGUAGE plpgsql AS $$
DECLARE
    env                   GEOMETRY;
    t                     RECORD;
    tile_count            INT  := 0;
    total_points_deleted  INT  := 0;
    total_points_inserted INT  := 0;
    total_lines_updated   INT  := 0;
    total_polygons_updated INT := 0;
    ins_per_tile          INT  := 2;     -- points to insert per tile
    del_count             INT;
    upd_count             INT;
BEGIN
    RAISE NOTICE
        'Starting 5-minute change simulation (%.2f%% of tiles at zoom %)…',
        pct * 100, z;

    FOR t IN SELECT * FROM pick_tiles_for_tick(z, pct)
    LOOP
        tile_count := tile_count + 1;
        env := ST_TileEnvelope(z, t.x, t.y);

        -- Delete up to 2 points inside the tile
        WITH candidates AS (
            SELECT id
            FROM demo_points
            WHERE geom && env AND ST_Intersects(geom, env)
            ORDER BY random()
            LIMIT 2
        ),
        deleted AS (
            DELETE FROM demo_points dp
            USING candidates c
            WHERE dp.id = c.id
            RETURNING dp.id
        )
        SELECT COUNT(*) INTO del_count FROM deleted;

        total_points_deleted := total_points_deleted + del_count;

        -- Insert new points
        INSERT INTO demo_points(geom, demo_tag)
        SELECT
            ST_SetSRID(
                ST_MakePoint(
                    ST_XMin(env) + random() * (ST_XMax(env)-ST_XMin(env)),
                    ST_YMin(env) + random() * (ST_YMax(env)-ST_YMin(env))
                ), 3857
            ),
            format(
                'sim_%s_point_%s_%s',
                extract(epoch FROM now())::INT,
                t.x, t.y
            )
        FROM generate_series(1, ins_per_tile);

        total_points_inserted := total_points_inserted + ins_per_tile;

        -- Slightly translate the tile's line (stay within tile)
        WITH updated_lines AS (
            UPDATE demo_lines
            SET  geom       = ST_Translate(
                                geom,
                                (random()-0.5) * 60,
                                (random()-0.5) * 60
                              ),
                 updated_at = now()
            WHERE demo_tag = format('tile_%s_%s_line', t.x, t.y)
              AND geom && env
            RETURNING id
        )
        SELECT COUNT(*) INTO upd_count FROM updated_lines;

        total_lines_updated := total_lines_updated + upd_count;

        -- Adjust the polygon size a bit (stay within tile)
        WITH updated_polygons AS (
            UPDATE demo_polygons
            SET  geom       = ST_Buffer(
                                ST_Centroid(geom),
                                GREATEST(50, LEAST(180, 180 + (random()-0.5) * 100))
                              ),
                 updated_at = now()
            WHERE demo_tag = format('tile_%s_%s_polygon', t.x, t.y)
              AND geom && env
            RETURNING id
        )
        SELECT COUNT(*) INTO upd_count FROM updated_polygons;

        total_polygons_updated := total_polygons_updated + upd_count;
    END LOOP;

    -- return summary
    selected_tiles    := tile_count;
    points_deleted    := total_points_deleted;
    points_inserted   := total_points_inserted;
    lines_updated     := total_lines_updated;
    polygons_updated  := total_polygons_updated;

    RAISE NOTICE
        'Simulation complete: % tiles (%.2f%%), % pts-del, % pts-ins, % lines, % polys',
        tile_count,
        tile_count::FLOAT / (1 << z)^2 * 100,
        total_points_deleted,
        total_points_inserted,
        total_lines_updated,
        total_polygons_updated;

    RETURN NEXT;
END;
$$;

-----------------------------------------------------------------------
--  Convenience wrapper (kept for shell script)
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION run_synthetic_simulation()
RETURNS VOID
LANGUAGE sql AS $$
    SELECT simulate_changes_5min() INTO TEMP TABLE sim_results;
$$;

-----------------------------------------------------------------------
--  Test helper: how many tiles would be picked right now?
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION test_tile_selection(
    z   INT    DEFAULT 8,
    pct FLOAT8 DEFAULT 0.05
)
RETURNS TABLE (
    total_tiles      BIGINT,
    selected_tiles   BIGINT,
    actual_percentage NUMERIC
)
LANGUAGE sql AS $$
    WITH picked AS (
        SELECT COUNT(*)::NUMERIC AS sel
        FROM   pick_tiles_for_tick(z, pct)
    ),
    total AS (
        SELECT ((1 << z)^2)::NUMERIC AS ttl   -- e.g. 65 536 for z8
    )
    SELECT
        ttl::BIGINT,
        sel::BIGINT,
        ROUND(sel / ttl * 100, 2)
    FROM total, picked;
$$;

-----------------------------------------------------------------------
--  Debug helper: show first 20 tiles selected for current tick
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION show_current_tick_tiles(
    z   INT    DEFAULT 8,
    pct FLOAT8 DEFAULT 0.05
)
RETURNS TABLE (tile_x INT, tile_y INT)
LANGUAGE sql AS $$
    SELECT x, y
    FROM   pick_tiles_for_tick(z, pct)
    ORDER  BY x, y
    LIMIT  20;
$$;
