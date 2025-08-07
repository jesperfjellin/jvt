-- 04-synthetic-change-simulator.sql (FIXED)
-- User‑initiated simulation for JVT demo

/* --------------------------------------------------------------------
   Helper: seeded_random(seed_val BIGINT) → FLOAT8
-------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION seeded_random(seed_val BIGINT)
RETURNS FLOAT8
LANGUAGE plpgsql AS $$
DECLARE
    a CONSTANT BIGINT := 1664525;
    c CONSTANT BIGINT := 1013904223;
    m CONSTANT BIGINT := 4294967296;
    result BIGINT;
BEGIN
    result := (a * seed_val + c) % m;
    RETURN result::FLOAT8 / m::FLOAT8;
END;
$$;

/* --------------------------------------------------------------------
   Helper: pick_tiles_for_tick(z INT, pct FLOAT8, seed_val INT) → TABLE(x INT, y INT)
-------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION pick_tiles_for_tick(
    z   INT,
    pct FLOAT8,
    seed_val INT DEFAULT 12345
)
RETURNS TABLE (x INT, y INT)
LANGUAGE plpgsql AS $$
DECLARE
    n INT := 1 << z;
    target_tiles INT;
    current_seed BIGINT;
    pseudo_random FLOAT8;
    tile_x INT;
    tile_y INT;
    selected_count INT := 0;
BEGIN
    target_tiles := floor(n * n * pct);
    current_seed := seed_val + (z * 1000) + floor(pct * 10000);

    -- Deterministic selection with guaranteed exact count and varied placement
    -- Use reservoir sampling approach for even distribution
    DECLARE
        total_tiles INT := n * n;
        tiles_processed INT := 0;
        remaining_tiles INT;
        remaining_needed INT;
        selection_probability FLOAT8;
    BEGIN
        FOR tile_x IN 0..n-1 LOOP
            FOR tile_y IN 0..n-1 LOOP
                tiles_processed := tiles_processed + 1;
                remaining_tiles := total_tiles - tiles_processed + 1;
                remaining_needed := target_tiles - selected_count;
                
                -- Calculate exact probability needed to select remaining tiles
                selection_probability := remaining_needed::FLOAT8 / remaining_tiles::FLOAT8;
                
                -- Generate deterministic pseudo-random value
                current_seed := (current_seed * 1103515245 + 12345) % 2147483648;
                pseudo_random := (current_seed % 1000000)::FLOAT8 / 1000000.0;
                
                -- Select if pseudo_random is less than required probability
                IF pseudo_random < selection_probability THEN
                    x := tile_x;
                    y := tile_y;
                    selected_count := selected_count + 1;
                    RETURN NEXT;
                END IF;
                
                -- Early exit if we have all tiles we need
                IF selected_count >= target_tiles THEN
                    RETURN;
                END IF;
            END LOOP;
        END LOOP;
    END;
END;
$$;

/* --------------------------------------------------------------------
   Main simulation function
-------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION simulate_tile_changes(
    p_zoom INT    DEFAULT 8,
    p_pct  FLOAT8 DEFAULT 0.05,
    p_seed INT    DEFAULT 12345
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
    env                    GEOMETRY;
    t                      RECORD;
    tile_count             INT  := 0;
    total_points_deleted   INT  := 0;
    total_points_inserted  INT  := 0;
    total_lines_updated    INT  := 0;
    total_polygons_updated INT  := 0;
    ins_per_tile           INT  := 2;
    del_count              INT;
    upd_count              INT;
    tile_seed              BIGINT;
    rand_x1                FLOAT8;
    rand_y1                FLOAT8;
    rand_translate_x       FLOAT8;
    rand_translate_y       FLOAT8;
    rand_buffer            FLOAT8;
    point_idx              INT;
    tile_margin            FLOAT8 := 50.0;
BEGIN
    RAISE NOTICE 'Starting interactive tile simulation (% %% of tiles at zoom %) with seed %',
        ROUND((p_pct * 100)::NUMERIC, 1), p_zoom, p_seed;

    FOR t IN SELECT * FROM pick_tiles_for_tick(p_zoom, p_pct, p_seed)
    LOOP
        tile_count := tile_count + 1;
        env := ST_TileEnvelope(p_zoom, t.x, t.y);
        tile_seed := p_seed + (t.x * 1000) + (t.y * 100000) + (p_zoom * 10000000) + floor(p_pct * 1000000);

        -- Delete up to 2 points inside the tile
        WITH candidates AS (
            SELECT id FROM demo_points
            WHERE geom && env AND ST_Intersects(geom, env)
            ORDER BY id LIMIT 2
        ),
        deleted AS (
            DELETE FROM demo_points dp USING candidates c
            WHERE dp.id = c.id RETURNING dp.id
        )
        SELECT COUNT(*) INTO del_count FROM deleted;

        total_points_deleted := total_points_deleted + del_count;

        -- Insert new points
        FOR point_idx IN 1..ins_per_tile LOOP
            rand_x1 := seeded_random(tile_seed + point_idx);
            rand_y1 := seeded_random(tile_seed + point_idx + 1000);

            INSERT INTO demo_points(geom, demo_tag)
            VALUES (
                ST_SetSRID(
                    ST_MakePoint(
                        ST_XMin(env) + tile_margin + rand_x1 * (ST_XMax(env) - ST_XMin(env) - 2 * tile_margin),
                        ST_YMin(env) + tile_margin + rand_y1 * (ST_YMax(env) - ST_YMin(env) - 2 * tile_margin)
                    ), 3857
                ),
                format('sim_%s_point_%s_%s_%s', p_seed, t.x, t.y, point_idx)
            );
        END LOOP;

        total_points_inserted := total_points_inserted + ins_per_tile;

        -- Update lines
        rand_translate_x := (seeded_random(tile_seed + 2000) - 0.5) * 0.5;
        rand_translate_y := (seeded_random(tile_seed + 3000) - 0.5) * 0.5;

        WITH updated_lines AS (
            UPDATE demo_lines
            SET geom = ST_Translate(geom, rand_translate_x * 60, rand_translate_y * 60),
                updated_at = now()
            WHERE demo_tag = format('tile_%s_%s_line', t.x, t.y) AND geom && env
            RETURNING id
        )
        SELECT COUNT(*) INTO upd_count FROM updated_lines;

        total_lines_updated := total_lines_updated + upd_count;

        -- Update polygons
        rand_buffer := (seeded_random(tile_seed + 4000) - 0.5) * 0.3;

        WITH updated_polygons AS (
            UPDATE demo_polygons
            SET geom = ST_Buffer(ST_Centroid(geom), GREATEST(100, LEAST(160, 130 + rand_buffer * 60))),
                updated_at = now()
            WHERE demo_tag = format('tile_%s_%s_polygon', t.x, t.y) AND geom && env
            RETURNING id
        )
        SELECT COUNT(*) INTO upd_count FROM updated_polygons;

        total_polygons_updated := total_polygons_updated + upd_count;
    END LOOP;

    selected_tiles    := tile_count;
    points_deleted    := total_points_deleted;
    points_inserted   := total_points_inserted;
    lines_updated     := total_lines_updated;
    polygons_updated  := total_polygons_updated;

    /* --------------------------------------------------------------
       Write to simulation_tiles & changed_tiles (unambiguous refs)
    -------------------------------------------------------------- */
    INSERT INTO simulation_tiles (z, x, y)
    SELECT p_zoom, pt.x, pt.y
    FROM   pick_tiles_for_tick(p_zoom, p_pct, p_seed) AS pt
    ON CONFLICT (z, x, y) DO NOTHING;

    INSERT INTO changed_tiles (z, x, y, source_table, operation, changed_at, processed_at)
    SELECT p_zoom, pt.x, pt.y,
           'simulation'::text, 'UPDATE'::text, NOW(), NULL
    FROM   pick_tiles_for_tick(p_zoom, p_pct, p_seed) AS pt
    ON CONFLICT (z, x, y) DO UPDATE SET
        changed_at   = EXCLUDED.changed_at,
        source_table = EXCLUDED.source_table,
        operation    = EXCLUDED.operation,
        processed_at = NULL;

    NOTIFY tiles_updated;
    PERFORM pg_sleep(0.1);

    RETURN NEXT;  -- returns the single summary row
    RETURN;
END;
$$;
