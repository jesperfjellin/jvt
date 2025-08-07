/***********************************************************************
  08-simple-simulation-tracking.sql
  ----------------------------------------------------------------------
  Simple simulation tracking using a dedicated simulation_tiles table.
  
  This provides a clean approach:
  • Each simulation starts with a fresh simulation_tiles table
  • No complex snapshot/restore logic
  • Simple and reliable tile counting
 ***********************************************************************/

-----------------------------------------------------------------------
--  Simple simulation tiles tracking table
-----------------------------------------------------------------------

-- Table to track tiles processed in current simulation
CREATE TABLE IF NOT EXISTS simulation_tiles (
    z SMALLINT NOT NULL,
    x INTEGER NOT NULL,
    y INTEGER NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    processed_at TIMESTAMPTZ DEFAULT NULL,
    PRIMARY KEY (z, x, y)
);

-- Indexes for efficient queries
CREATE INDEX IF NOT EXISTS idx_simulation_tiles_processed ON simulation_tiles (processed_at);
CREATE INDEX IF NOT EXISTS idx_simulation_tiles_created ON simulation_tiles (created_at);

-----------------------------------------------------------------------
--  Function: clear_simulation_tiles()
--  Drops and recreates the simulation_tiles table for a fresh start
-----------------------------------------------------------------------

CREATE OR REPLACE FUNCTION clear_simulation_tiles()
RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
    -- Drop and recreate the table for a completely fresh start
    DROP TABLE IF EXISTS simulation_tiles;
    
    CREATE TABLE simulation_tiles (
        z SMALLINT NOT NULL,
        x INTEGER NOT NULL,
        y INTEGER NOT NULL,
        created_at TIMESTAMPTZ DEFAULT NOW(),
        processed_at TIMESTAMPTZ DEFAULT NULL,
        PRIMARY KEY (z, x, y)
    );
    
    CREATE INDEX idx_simulation_tiles_processed ON simulation_tiles (processed_at);
    CREATE INDEX idx_simulation_tiles_created ON simulation_tiles (created_at);
    
    RAISE NOTICE 'Simulation tiles table cleared and recreated';
END;
$$;

-----------------------------------------------------------------------
--  Function: get_simulation_pending_tiles()
--  Returns tiles that need to be processed by the worker
-----------------------------------------------------------------------

CREATE OR REPLACE FUNCTION get_simulation_pending_tiles(batch_limit INT DEFAULT 1000)
RETURNS TABLE (z SMALLINT, x INT, y INT, count BIGINT)
LANGUAGE sql AS $$
    SELECT 
        st.z,
        st.x,
        st.y,
        1 as count  -- Each tile processed once in simulation
    FROM simulation_tiles st
    WHERE st.processed_at IS NULL  -- Only return unprocessed tiles
    ORDER BY st.created_at
    LIMIT batch_limit;
$$;

-----------------------------------------------------------------------
--  Function: get_simulation_tile_count()
--  Returns the count of tiles processed in current simulation
-----------------------------------------------------------------------

CREATE OR REPLACE FUNCTION get_simulation_tile_count()
RETURNS INTEGER
LANGUAGE sql AS $$
    SELECT COUNT(*) FROM simulation_tiles;
$$;

-----------------------------------------------------------------------
--  Function: is_tile_in_simulation(z, x, y)
--  Checks if a specific tile was processed in current simulation
-----------------------------------------------------------------------

CREATE OR REPLACE FUNCTION is_tile_in_simulation(
    tile_z SMALLINT,
    tile_x INTEGER,
    tile_y INTEGER
)
RETURNS BOOLEAN
LANGUAGE sql AS $$
    SELECT EXISTS(
        SELECT 1 FROM simulation_tiles 
        WHERE z = tile_z AND x = tile_x AND y = tile_y
    );
$$;

-----------------------------------------------------------------------
--  Function: add_tile_to_simulation(z, x, y)
--  Adds a tile to the current simulation tracking
-----------------------------------------------------------------------

CREATE OR REPLACE FUNCTION add_tile_to_simulation(
    tile_z SMALLINT,
    tile_x INTEGER,
    tile_y INTEGER
)
RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO simulation_tiles (z, x, y) 
    VALUES (tile_z, tile_x, tile_y)
    ON CONFLICT (z, x, y) DO NOTHING;
END;
$$;

-----------------------------------------------------------------------
--  Function: get_simulation_fresh_tiles()
--  Returns tiles that were processed in current simulation (for API)
-----------------------------------------------------------------------

CREATE OR REPLACE FUNCTION get_simulation_fresh_tiles()
RETURNS TABLE (
    z SMALLINT,
    x INTEGER,
    y INTEGER,
    last_processed TIMESTAMPTZ,
    is_fresh BOOLEAN,
    change_count INTEGER,
    seconds_since_update FLOAT8
)
LANGUAGE sql AS $$
    SELECT 
        st.z,
        st.x,
        st.y,
        st.processed_at as last_processed,
        (st.processed_at IS NOT NULL) as is_fresh,  -- Only processed tiles are fresh
        1 as change_count, -- Each tile processed once in simulation
        CASE 
            WHEN st.processed_at IS NOT NULL THEN EXTRACT(EPOCH FROM (NOW() - st.processed_at))::FLOAT8
            ELSE NULL
        END as seconds_since_update
    FROM simulation_tiles st
    ORDER BY st.z, st.x, st.y;
$$;

-----------------------------------------------------------------------
--  Function: get_simulation_tile_status()
--  Returns summary of simulation tile status for API
-----------------------------------------------------------------------

CREATE OR REPLACE FUNCTION get_simulation_tile_status()
RETURNS TABLE (
    fresh_count BIGINT,
    stale_count BIGINT,
    total_tiles BIGINT
)
LANGUAGE sql AS $$
    SELECT 
        (SELECT COUNT(*) FROM simulation_tiles WHERE processed_at IS NOT NULL) as fresh_count,
        (SELECT 65536 - COUNT(*) FROM simulation_tiles WHERE processed_at IS NOT NULL) as stale_count,
        65536 as total_tiles;
$$;

-----------------------------------------------------------------------
--  Initialize: Clear simulation tiles on startup
-----------------------------------------------------------------------

SELECT clear_simulation_tiles();

-----------------------------------------------------------------------
--  Completion notice
-----------------------------------------------------------------------

SELECT 'Simple simulation tracking installed successfully' AS status; 