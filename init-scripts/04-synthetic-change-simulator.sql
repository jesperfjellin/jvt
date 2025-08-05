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
--  Helper: generate_cluster_centers()
--  ----------------------------------
--  Generates 5-7 cluster centers that drift over time
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION generate_cluster_centers(
    z INT DEFAULT 8
)
RETURNS TABLE (center_x FLOAT, center_y FLOAT, cluster_id INT)
LANGUAGE plpgsql AS $$
DECLARE
    n INT := 1 << z;  -- tiles per side (256 for z=8)
    time_cycle INT;
    num_clusters INT;
    base_seed INT;
    i INT;
    drift_x FLOAT;
    drift_y FLOAT;
BEGIN
    -- Time-based cycle (changes every 15 minutes for slower drift)
    time_cycle := (floor(extract(epoch FROM now()) / 900) % 10000)::INT;
    
    -- Random number of clusters (5-7)
    SELECT 5 + (time_cycle % 3) INTO num_clusters;
    
    -- Base seed for reproducible randomness within each cycle
    base_seed := (time_cycle % 1000) * 123;
    
    FOR i IN 1..num_clusters LOOP
        -- Create pseudo-random but deterministic cluster centers
        -- Each cluster drifts in a circular pattern over time
        drift_x := sin(time_cycle * 0.1 + i * 2.0) * (n * 0.15);
        drift_y := cos(time_cycle * 0.1 + i * 1.7) * (n * 0.15);
        
        center_x := (n * 0.5) + drift_x + 
                   ((base_seed + i * 79) % (n/2)) - (n/4);
        center_y := (n * 0.5) + drift_y + 
                   ((base_seed + i * 97) % (n/2)) - (n/4);
        
        -- Keep centers within bounds
        center_x := GREATEST(n * 0.1, LEAST(n * 0.9, center_x));
        center_y := GREATEST(n * 0.1, LEAST(n * 0.9, center_y));
        
        cluster_id := i;
        
        RETURN NEXT;
    END LOOP;
END;
$$;

-----------------------------------------------------------------------
--  Helper: pick_tiles_for_tick()
--  --------------------------------
--  Selects tiles using clustering algorithm with 5-10% coverage.
--  Creates 5-7 clusters that drift over time, with weighted selection
--  step = floor(1/pct)   →   1 tile out of every “step” is chosen.
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pick_tiles_for_tick(
    z   INT,          -- zoom level (only 8 used in demo)
    pct FLOAT8        -- fraction to pick (e.g. 0.075 = 7.5%)
)
RETURNS TABLE (x INT, y INT)
LANGUAGE plpgsql AS $$
DECLARE
    n INT := 1 << z;  -- tiles per side
    target_tiles INT;
    time_seed INT;
    cluster_rec RECORD;
    cluster_radius FLOAT;
    tiles_per_cluster INT;
    remaining_tiles INT;
BEGIN
    -- Calculate target number of tiles (5-10% with some randomness)
    time_seed := (floor(extract(epoch FROM now()) / 300) % 10000)::INT;
    target_tiles := floor(n * n * (pct + (time_seed % 100) * 0.0005));
    
    -- Get cluster centers
    remaining_tiles := target_tiles;
    
    FOR cluster_rec IN SELECT * FROM generate_cluster_centers(z) LOOP
        -- Vary cluster size (some big, some small)
        cluster_radius := 8 + (cluster_rec.cluster_id * 3) % 12;
        tiles_per_cluster := GREATEST(1, remaining_tiles / 3);
        
        -- Select tiles around this cluster center
        RETURN QUERY
        WITH cluster_tiles AS (
            SELECT 
                gx, gy,
                sqrt(power(gx - cluster_rec.center_x, 2) + 
                     power(gy - cluster_rec.center_y, 2)) as distance
            FROM generate_series(
                GREATEST(0, floor(cluster_rec.center_x - cluster_radius)::INT),
                LEAST(n-1, floor(cluster_rec.center_x + cluster_radius)::INT)
            ) AS gx,
            generate_series(
                GREATEST(0, floor(cluster_rec.center_y - cluster_radius)::INT),
                LEAST(n-1, floor(cluster_rec.center_y + cluster_radius)::INT)
            ) AS gy
            WHERE sqrt(power(gx - cluster_rec.center_x, 2) + 
                      power(gy - cluster_rec.center_y, 2)) <= cluster_radius
        ),
        weighted_selection AS (
            SELECT 
                gx, gy, distance,
                -- Probability decreases with distance from center
                random() * (cluster_radius - distance + 1) as weight
            FROM cluster_tiles
        )
        SELECT gx::INT, gy::INT
        FROM weighted_selection
        ORDER BY weight DESC
        LIMIT tiles_per_cluster;
        
        remaining_tiles := remaining_tiles - tiles_per_cluster;
        EXIT WHEN remaining_tiles <= 0;
    END LOOP;
    
    -- Add some random scattered tiles to reach target percentage
    IF remaining_tiles > 0 THEN
        RETURN QUERY
        SELECT 
            floor(random() * n)::INT,
            floor(random() * n)::INT
        FROM generate_series(1, remaining_tiles);
    END IF;
END;
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

    -- Notify the worker that tiles are ready for processing
    NOTIFY tiles_updated;

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
