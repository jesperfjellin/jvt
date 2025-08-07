/***********************************************************************
  08-simple-simulation-tracking.sql  ── FIXED
  ----------------------------------------------------------------------
  Simple simulation–tile tracking that is

  • Schema-compatible with the simulator      (z INT, x INT, y INT)
  • Idempotent                                (safe on every rebuild)
  • Worker-compatible                         (get_simulation_pending_tiles(text,int))
***********************************************************************/

-----------------------------------------------------------------------
--  1. Ensure simulation_tiles table exists and has the right columns
-----------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE  table_schema = 'public'
          AND  table_name   = 'simulation_tiles'
    ) THEN
        CREATE TABLE simulation_tiles (
            z INT  NOT NULL,
            x INT  NOT NULL,
            y INT  NOT NULL,
            created_at  TIMESTAMPTZ DEFAULT NOW(),
            processed_at TIMESTAMPTZ,
            PRIMARY KEY (z, x, y)
        );
    END IF;

    -- Bring an existing table up-to-date
    ALTER TABLE simulation_tiles
        ALTER COLUMN z TYPE INT USING z::INT,
        ADD COLUMN   IF NOT EXISTS created_at  TIMESTAMPTZ DEFAULT NOW(),
        ADD COLUMN   IF NOT EXISTS processed_at TIMESTAMPTZ;

    -- Indexes (no-ops if already present)
    CREATE INDEX IF NOT EXISTS idx_simulation_tiles_processed
        ON simulation_tiles (processed_at);
    CREATE INDEX IF NOT EXISTS idx_simulation_tiles_created
        ON simulation_tiles (created_at);
END$$;

-----------------------------------------------------------------------
-- 2. clear_simulation_tiles — truncate instead of drop
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION clear_simulation_tiles()
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    TRUNCATE TABLE simulation_tiles;
    RAISE NOTICE 'simulation_tiles truncated – fresh start';
END;
$$;

-----------------------------------------------------------------------
-- 3. get_simulation_pending_tiles — signature worker expects
-----------------------------------------------------------------------
DROP FUNCTION IF EXISTS get_simulation_pending_tiles(INT);        -- <<< remove legacy overload

-- Function with single parameter that Rust code expects
CREATE OR REPLACE FUNCTION get_simulation_pending_tiles(
    batch_limit  INT  DEFAULT 1000
)
RETURNS TABLE (z INT, x INT, y INT, count BIGINT)
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT st.z, st.x, st.y, 1::BIGINT
    FROM   simulation_tiles st
    WHERE  st.processed_at IS NULL
    ORDER  BY st.created_at
    LIMIT  batch_limit
$$;

-----------------------------------------------------------------------
-- 4. Remaining helper functions (unchanged API, INT for z)
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_simulation_tile_count()
RETURNS BIGINT
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT COUNT(*) FROM simulation_tiles
$$;

CREATE OR REPLACE FUNCTION is_tile_in_simulation(
    tile_z INT, tile_x INT, tile_y INT
)
RETURNS BOOLEAN
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT EXISTS (
        SELECT 1 FROM simulation_tiles
        WHERE  z = tile_z AND x = tile_x AND y = tile_y
    )
$$;

CREATE OR REPLACE FUNCTION add_tile_to_simulation(
    tile_z INT, tile_x INT, tile_y INT
)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO simulation_tiles (z, x, y)
    VALUES (tile_z, tile_x, tile_y)
    ON CONFLICT DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION get_simulation_fresh_tiles()
RETURNS TABLE (
    z INT, x INT, y INT,
    last_processed TIMESTAMPTZ,
    is_fresh BOOLEAN,
    change_count INT,
    seconds_since_update FLOAT8
)
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT
        st.z, st.x, st.y,
        st.processed_at,
        st.processed_at IS NOT NULL,
        1,
        CASE
            WHEN st.processed_at IS NOT NULL
            THEN EXTRACT(EPOCH FROM (NOW() - st.processed_at))
        END
    FROM simulation_tiles st
    ORDER BY st.z, st.x, st.y
$$;

CREATE OR REPLACE FUNCTION get_simulation_tile_status()
RETURNS TABLE (
    fresh_count BIGINT,
    stale_count BIGINT,
    total_tiles BIGINT
)
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT
        (SELECT COUNT(*) FROM simulation_tiles WHERE processed_at IS NOT NULL),
        (SELECT 65536 - COUNT(*) FROM simulation_tiles WHERE processed_at IS NOT NULL),
        65536
$$;

-----------------------------------------------------------------------
-- 5. Initialise table on every container build
-----------------------------------------------------------------------
SELECT clear_simulation_tiles();

-----------------------------------------------------------------------
-- 6. Banner
-----------------------------------------------------------------------
SELECT 'Simple simulation tracking installed successfully' AS status;
