/* ================================================================
   04-synthetic-change-simulation.sql
   Complete JVT simulation schema (tables + functions)
   Last updated: 2025-08-07
   ================================================================ */

/* ----------------------------------------------------------------
   Ensure PostGIS is available
----------------------------------------------------------------- */
CREATE EXTENSION IF NOT EXISTS postgis;

/* ----------------------------------------------------------------
   Metadata tables required by the worker
----------------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS simulation_tiles (
    z INT NOT NULL,
    x INT NOT NULL,
    y INT NOT NULL,
    PRIMARY KEY (z, x, y)
);

CREATE TABLE IF NOT EXISTS changed_tiles (
    z INT NOT NULL,
    x INT NOT NULL,
    y INT NOT NULL,
    source_table  TEXT NOT NULL,
    operation     TEXT NOT NULL,
    changed_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    processed_at  TIMESTAMPTZ,
    PRIMARY KEY (z, x, y)
);

/* ----------------------------------------------------------------
   Utility functions the worker invokes on start-up
----------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION clear_simulation_tiles()
RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM simulation_tiles;
    DELETE FROM changed_tiles WHERE source_table = 'simulation';
END;
$$;

CREATE OR REPLACE FUNCTION is_simulation_running()
RETURNS BOOLEAN
LANGUAGE sql AS $$
    SELECT EXISTS (SELECT 1 FROM simulation_tiles LIMIT 1);
$$;

/* ----------------------------------------------------------------
   Helper: seeded_random(seed_val BIGINT) → FLOAT8
----------------------------------------------------------------- */
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

/* ----------------------------------------------------------------
   Helper: pick_tiles_for_tick(z INT, pct FLOAT8, seed_val INT)
   • Guarantees UNIQUE (z,x,y) tiles
   • Handles pct = 1.0 (100 %) by streaming every tile once
----------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION pick_tiles_for_tick(
    z        INT,
    pct      FLOAT8,
    seed_val INT DEFAULT 12345
)
RETURNS TABLE (x INT, y INT)
LANGUAGE plpgsql AS $$
DECLARE
    n            INT := 1 << z;                     -- tiles per axis
    target_tiles INT := FLOOR(n * n * pct);         -- how many to emit
    picked       INT := 0;                          -- emitted so far
    ----------------------------------------------------------------
    -- rectangle / RNG variables
    current_seed BIGINT := seed_val + (z * 1000) + FLOOR(pct * 10000);
    num_clusters INT;
    rect_x       INT;
    rect_y       INT;
    rect_w       INT;
    rect_h       INT;
BEGIN
    /* ---------- 1. Fast path: 100 % → full grid ------------------ */
    IF pct >= 1 THEN
        RETURN QUERY
        SELECT i, j
        FROM   generate_series(0, n-1) AS i,
               generate_series(0, n-1) AS j;
        RETURN;
    END IF;

    /* ---------- 2. General case: clustered but unique ------------ */
    DROP TABLE IF EXISTS _picked;
    CREATE TEMP TABLE _picked (
        x INT,
        y INT,
        PRIMARY KEY (x, y)
    ) ON COMMIT DROP;

    /* decide 4-6 clusters */
    current_seed := (current_seed * 1103515245 + 12345) % 2147483648;
    num_clusters := 4 + (current_seed % 3);

    <<cluster_loop>>
    FOR c IN 1..num_clusters LOOP
        EXIT WHEN picked >= target_tiles;

        /* rectangle size (10-59) trimmed to quota */
        current_seed := (current_seed * 1103515245 + 12345) % 2147483648;
        rect_w := LEAST(10 + (current_seed % 50), n);

        current_seed := (current_seed * 1103515245 + 12345) % 2147483648;
        rect_h := LEAST(10 + (current_seed % 50), n);

        IF rect_w * rect_h > (target_tiles - picked) THEN
            rect_w := LEAST(rect_w, target_tiles - picked);
            rect_h := CEIL( (target_tiles - picked)::NUMERIC / rect_w );
        END IF;

        /* rectangle position */
        current_seed := (current_seed * 1103515245 + 12345) % 2147483648;
        rect_x := current_seed % (n - rect_w);

        current_seed := (current_seed * 1103515245 + 12345) % 2147483648;
        rect_y := current_seed % (n - rect_h);

        /* emit tiles, skipping duplicates */
        FOR tx IN rect_x .. rect_x + rect_w - 1 LOOP
            EXIT cluster_loop WHEN picked >= target_tiles;
            FOR ty IN rect_y .. rect_y + rect_h - 1 LOOP
                EXIT cluster_loop WHEN picked >= target_tiles;
                BEGIN
                    INSERT INTO _picked VALUES (tx, ty);
                    x := tx; y := ty;
                    picked := picked + 1;
                    RETURN NEXT;
                EXCEPTION WHEN unique_violation THEN
                    -- defer to fallback later
                END;
            END LOOP;
        END LOOP;
    END LOOP cluster_loop;

    /* ---------- 3. Fallback: fill remaining quota ---------------- */
    WHILE picked < target_tiles LOOP
        /* 3a. 10 random probes */
        FOR i IN 1..10 LOOP
            EXIT WHEN picked >= target_tiles;
            current_seed := (current_seed * 1103515245 + 12345) % 2147483648;
            x := current_seed % n;
            current_seed := (current_seed * 1103515245 + 12345) % 2147483648;
            y := current_seed % n;
            BEGIN
                INSERT INTO _picked VALUES (x, y);
                picked := picked + 1;
                RETURN NEXT;
            EXCEPTION WHEN unique_violation THEN
                -- keep trying
            END;
        END LOOP;

        /* 3b. deterministic scan (guaranteed to finish) */
        FOR tx IN 0 .. n-1 LOOP
            EXIT WHEN picked >= target_tiles;
            FOR ty IN 0 .. n-1 LOOP
                EXIT WHEN picked >= target_tiles;
                BEGIN
                    INSERT INTO _picked VALUES (tx, ty);
                    x := tx; y := ty;
                    picked := picked + 1;
                    RETURN NEXT;
                EXCEPTION WHEN unique_violation THEN
                    -- already used
                END;
            END LOOP;
        END LOOP;
    END LOOP;
END;
$$;

/* ----------------------------------------------------------------
   Main simulation function
   (unchanged logic; now safe because helper never duplicates)
----------------------------------------------------------------- */
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
    polygons_updated  INT,
    bbox_min_x        INT,
    bbox_min_y        INT,
    bbox_max_x        INT,
    bbox_max_y        INT
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
    /* bbox tracking */
    min_tile_x             INT := 999999;
    min_tile_y             INT := 999999;
    max_tile_x             INT := -1;
    max_tile_y             INT := -1;
BEGIN
    RAISE NOTICE 'Starting interactive tile simulation (% %% of tiles at zoom %) with seed %',
        ROUND((p_pct * 100)::NUMERIC, 1), p_zoom, p_seed;

    /* ------------- MAIN LOOP over unique tiles ------------------- */
    FOR t IN SELECT * FROM pick_tiles_for_tick(p_zoom, p_pct, p_seed) LOOP
        tile_count := tile_count + 1;
        env := ST_TileEnvelope(p_zoom, t.x, t.y);

        /* bbox update */
        min_tile_x := LEAST(min_tile_x, t.x);
        min_tile_y := LEAST(min_tile_y, t.y);
        max_tile_x := GREATEST(max_tile_x, t.x);
        max_tile_y := GREATEST(max_tile_y, t.y);

        tile_seed := p_seed
                     + (t.x * 1000)
                     + (t.y * 100000)
                     + (p_zoom * 10000000)
                     + FLOOR(p_pct * 1000000);

        /* --- POINTS: delete up to 2 -------------------------------- */
        WITH candidates AS (
            SELECT id FROM demo_points
            WHERE geom && env AND ST_Intersects(geom, env)
            ORDER BY id LIMIT 2
        ),
        deleted AS (
            DELETE FROM demo_points dp
            USING candidates c
            WHERE dp.id = c.id
            RETURNING dp.id
        )
        SELECT COUNT(*) INTO del_count FROM deleted;

        total_points_deleted := total_points_deleted + del_count;

        /* --- POINTS: insert 2 -------------------------------------- */
        FOR point_idx IN 1..ins_per_tile LOOP
            rand_x1 := seeded_random(tile_seed + point_idx);
            rand_y1 := seeded_random(tile_seed + point_idx + 1000);

            INSERT INTO demo_points(geom, demo_tag)
            VALUES (
                ST_SetSRID(
                    ST_MakePoint(
                        ST_XMin(env) + tile_margin
                        + rand_x1 * (ST_XMax(env) - ST_XMin(env) - 2*tile_margin),
                        ST_YMin(env) + tile_margin
                        + rand_y1 * (ST_YMax(env) - ST_YMin(env) - 2*tile_margin)
                    ), 3857
                ),
                format('sim_%s_point_%s_%s_%s', p_seed, t.x, t.y, point_idx)
            );
        END LOOP;

        total_points_inserted := total_points_inserted + ins_per_tile;

        /* --- LINES: translate -------------------------------------- */
        rand_translate_x := (seeded_random(tile_seed + 2000) - 0.5) * 0.5;
        rand_translate_y := (seeded_random(tile_seed + 3000) - 0.5) * 0.5;

        WITH updated_lines AS (
            UPDATE demo_lines
            SET geom = ST_Translate(geom, rand_translate_x * 60, rand_translate_y * 60),
                updated_at = now()
            WHERE demo_tag = format('tile_%s_%s_line', t.x, t.y)
              AND geom && env
            RETURNING id
        )
        SELECT COUNT(*) INTO upd_count FROM updated_lines;

        total_lines_updated := total_lines_updated + upd_count;

        /* --- POLYGONS: buffer-jitter ------------------------------- */
        rand_buffer := (seeded_random(tile_seed + 4000) - 0.5) * 0.3;

        WITH updated_polygons AS (
            UPDATE demo_polygons
            SET geom = ST_Buffer(
                           ST_Centroid(geom),
                           GREATEST(100, LEAST(160, 130 + rand_buffer * 60))
                       ),
                updated_at = now()
            WHERE demo_tag = format('tile_%s_%s_polygon', t.x, t.y)
              AND geom && env
            RETURNING id
        )
        SELECT COUNT(*) INTO upd_count FROM updated_polygons;

        total_polygons_updated := total_polygons_updated + upd_count;
    END LOOP;

    /* --------- summary out --------------------------------------- */
    selected_tiles    := tile_count;
    points_deleted    := total_points_deleted;
    points_inserted   := total_points_inserted;
    lines_updated     := total_lines_updated;
    polygons_updated  := total_polygons_updated;
    bbox_min_x        := min_tile_x;
    bbox_min_y        := min_tile_y;
    bbox_max_x        := max_tile_x;
    bbox_max_y        := max_tile_y;

    /* --------- meta tables & notify ------------------------------ */
    INSERT INTO simulation_tiles (z, x, y)
    SELECT p_zoom, pt.x, pt.y
    FROM   pick_tiles_for_tick(p_zoom, p_pct, p_seed) AS pt
    ON CONFLICT (z, x, y) DO NOTHING;

    INSERT INTO changed_tiles (z, x, y, source_table, operation, changed_at, processed_at)
    SELECT p_zoom, pt.x, pt.y,
           'simulation', 'UPDATE', NOW(), NULL
    FROM   pick_tiles_for_tick(p_zoom, p_pct, p_seed) AS pt
    ON CONFLICT (z, x, y) DO UPDATE
        SET changed_at   = EXCLUDED.changed_at,
            source_table = EXCLUDED.source_table,
            operation    = EXCLUDED.operation,
            processed_at = NULL;

    NOTIFY tiles_updated;
    PERFORM pg_sleep(0.1);

    RETURN NEXT;  -- single summary row
END;
$$;
