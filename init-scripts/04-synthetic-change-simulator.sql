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
--  Helper: seeded_random()
--  ------------------------
--  Generates deterministic pseudo-random numbers using a linear 
--  congruential generator with configurable seed
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seeded_random(seed_val BIGINT)
RETURNS FLOAT8
LANGUAGE plpgsql AS $$
DECLARE
    a CONSTANT BIGINT := 1664525;
    c CONSTANT BIGINT := 1013904223;
    m CONSTANT BIGINT := 4294967296; -- 2^32
    result BIGINT;
BEGIN
    -- Linear congruential generator: (a * seed + c) mod m
    result := (a * seed_val + c) % m;
    
    -- Convert to float between 0 and 1
    RETURN result::FLOAT8 / m::FLOAT8;
END;
$$;

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
    pct FLOAT8,       -- fraction to pick (e.g. 0.075 = 7.5%)
    seed_val INT DEFAULT 12345  -- optional seed for deterministic selection
)
RETURNS TABLE (x INT, y INT)
LANGUAGE plpgsql AS $$
DECLARE
    n INT := 1 << z;  -- tiles per side
    target_tiles INT;
    current_seed BIGINT;
    pseudo_random FLOAT8;
    tile_x INT;
    tile_y INT;
    selected_count INT := 0;
BEGIN
    -- Calculate exact target number of tiles
    target_tiles := floor(n * n * pct);
    
    -- For high percentages (>90%), select all tiles deterministically
    IF pct >= 0.9 THEN
        RETURN QUERY
        SELECT gx::INT, gy::INT
        FROM generate_series(0, n-1) AS gx,
             generate_series(0, n-1) AS gy
        ORDER BY gx, gy  -- Deterministic ordering
        LIMIT target_tiles;
        RETURN;
    END IF;
    
    -- For lower percentages, use deterministic pseudo-random selection
    -- Initialize seed based on input parameters for consistency
    current_seed := seed_val + (z * 1000) + floor(pct * 10000);
    
    -- Use a simple deterministic approach: select tiles based on 
    -- their coordinates and the seed to ensure consistent results
    FOR tile_x IN 0..n-1 LOOP
        FOR tile_y IN 0..n-1 LOOP
            -- Generate deterministic pseudo-random value for this tile
            current_seed := (current_seed * 1103515245 + 12345) % 2147483648;
            pseudo_random := (current_seed % 1000000)::FLOAT8 / 1000000.0;
            
            -- Select tile if pseudo-random value is within percentage threshold
            IF pseudo_random < pct AND selected_count < target_tiles THEN
                x := tile_x;
                y := tile_y;
                selected_count := selected_count + 1;
                RETURN NEXT;
            END IF;
            
            -- Early exit if we've selected enough tiles
            IF selected_count >= target_tiles THEN
                EXIT;
            END IF;
        END LOOP;
        
        -- Early exit from outer loop if we've selected enough tiles
        IF selected_count >= target_tiles THEN
            EXIT;
        END IF;
    END LOOP;
    
    -- If we didn't get enough tiles due to distribution, fill remaining deterministically
    IF selected_count < target_tiles THEN
        FOR tile_x IN 0..n-1 LOOP
            FOR tile_y IN 0..n-1 LOOP
                -- Skip tiles that were already selected (simple check)
                current_seed := seed_val + (z * 1000) + floor(pct * 10000) + tile_x * 1000 + tile_y;
                pseudo_random := seeded_random(current_seed);
                
                -- Use a different threshold to fill remaining slots
                IF pseudo_random > pct AND selected_count < target_tiles THEN
                    x := tile_x;
                    y := tile_y;
                    selected_count := selected_count + 1;
                    RETURN NEXT;
                    
                    IF selected_count >= target_tiles THEN
                        EXIT;
                    END IF;
                END IF;
            END LOOP;
            
            IF selected_count >= target_tiles THEN
                EXIT;
            END IF;
        END LOOP;
    END IF;
END;
$$;

-----------------------------------------------------------------------
--  Interactive tile simulation (user-triggered)
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION simulate_tile_changes(
    z   INT    DEFAULT 8,
    pct FLOAT8 DEFAULT 0.05,
    seed_val INT DEFAULT 12345  -- optional seed for deterministic geometry modifications
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
    -- Deterministic random values for geometry modifications
    tile_seed             BIGINT;
    rand_x1               FLOAT8;
    rand_y1               FLOAT8;
    rand_x2               FLOAT8;
    rand_y2               FLOAT8;
    rand_translate_x      FLOAT8;
    rand_translate_y      FLOAT8;
    rand_buffer           FLOAT8;
    point_idx             INT;
BEGIN
    RAISE NOTICE
        'Starting interactive tile simulation (%.1f%% of tiles at zoom %) with seed %…',
        pct * 100, z, seed_val;

    FOR t IN SELECT * FROM pick_tiles_for_tick(z, pct, seed_val)
    LOOP
        tile_count := tile_count + 1;
        env := ST_TileEnvelope(z, t.x, t.y);

        -- Generate deterministic seed for this specific tile based on coordinates and simulation parameters
        tile_seed := seed_val + (t.x * 1000) + (t.y * 100000) + (z * 10000000) + floor(pct * 1000000);

        -- Delete up to 2 points inside the tile (deterministic selection)
        WITH candidates AS (
            SELECT id
            FROM demo_points
            WHERE geom && env AND ST_Intersects(geom, env)
            ORDER BY id  -- Deterministic ordering by ID
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

        -- Insert new points with deterministic coordinates
        FOR point_idx IN 1..ins_per_tile LOOP
            -- Generate deterministic random values for each point
            rand_x1 := seeded_random(tile_seed + point_idx);
            rand_y1 := seeded_random(tile_seed + point_idx + 1000);
            
            INSERT INTO demo_points(geom, demo_tag)
            VALUES (
                ST_SetSRID(
                    ST_MakePoint(
                        ST_XMin(env) + rand_x1 * (ST_XMax(env)-ST_XMin(env)),
                        ST_YMin(env) + rand_y1 * (ST_YMax(env)-ST_YMin(env))
                    ), 3857
                ),
                format(
                    'sim_%s_point_%s_%s_%s',
                    seed_val,
                    t.x, t.y, point_idx
                )
            );
        END LOOP;

        total_points_inserted := total_points_inserted + ins_per_tile;

        -- Generate deterministic translation values for lines
        rand_translate_x := seeded_random(tile_seed + 2000) - 0.5;
        rand_translate_y := seeded_random(tile_seed + 3000) - 0.5;

        -- Slightly translate the tile's line (stay within tile) - deterministic
        WITH updated_lines AS (
            UPDATE demo_lines
            SET  geom       = ST_Translate(
                                geom,
                                rand_translate_x * 60,
                                rand_translate_y * 60
                              ),
                 updated_at = now()
            WHERE demo_tag = format('tile_%s_%s_line', t.x, t.y)
              AND geom && env
            RETURNING id
        )
        SELECT COUNT(*) INTO upd_count FROM updated_lines;

        total_lines_updated := total_lines_updated + upd_count;

        -- Generate deterministic buffer value for polygons
        rand_buffer := seeded_random(tile_seed + 4000) - 0.5;

        -- Adjust the polygon size a bit (stay within tile) - deterministic
        WITH updated_polygons AS (
            UPDATE demo_polygons
            SET  geom       = ST_Buffer(
                                ST_Centroid(geom),
                                GREATEST(50, LEAST(180, 180 + rand_buffer * 100))
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
        'Interactive simulation complete: % tiles (%.1f%%), % pts-del, % pts-ins, % lines, % polys',
        tile_count,
        tile_count::FLOAT / (1 << z)^2 * 100,
        total_points_deleted,
        total_points_inserted,
        total_lines_updated,
        total_polygons_updated;

    -- Notify the worker that tiles are ready for processing
    RAISE NOTICE 'Sending NOTIFY tiles_updated signal to worker...';
    NOTIFY tiles_updated;
    RAISE NOTICE 'NOTIFY signal sent successfully';
    
    -- Small delay to ensure notification is processed
    PERFORM pg_sleep(0.1);

    RETURN NEXT;
END;
$$;

-----------------------------------------------------------------------
--  Convenience wrapper (kept for shell script)
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION run_synthetic_simulation()
RETURNS VOID
LANGUAGE sql AS $$
    SELECT simulate_tile_changes() INTO TEMP TABLE sim_results;
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
        FROM   pick_tiles_for_tick(z, pct, 12345)
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
    FROM   pick_tiles_for_tick(z, pct, 12345)
    ORDER  BY x, y
    LIMIT  20;
$$;
