/***********************************************************************
  06-simulation-state-reset-fixed.sql
  ----------------------------------------------------------------------
  Simulation state reset functionality for JVT demo.
  
  This provides mechanisms to:
  • Create snapshots of original demo data before simulations
  • Track simulation-generated vs original data
  • Reset simulation state while preserving original demo data
  • Handle partial simulation failures and recovery
***********************************************************************/

-----------------------------------------------------------------------
--  Simulation state tracking tables
-----------------------------------------------------------------------

-- Table to track simulation sessions and their state
CREATE TABLE IF NOT EXISTS simulation_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    percentage FLOAT8 NOT NULL,
    started_at TIMESTAMPTZ DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    status TEXT NOT NULL DEFAULT 'starting',
    snapshot_id TEXT,
    seed_value INT DEFAULT 12345
);

-- Table to store geometry snapshots for restoration
CREATE TABLE IF NOT EXISTS geometry_snapshots (
    id TEXT PRIMARY KEY,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    points_count INT DEFAULT 0,
    lines_count INT DEFAULT 0,
    polygons_count INT DEFAULT 0,
    is_baseline BOOLEAN DEFAULT FALSE
);

-- Backup tables for original demo data
CREATE TABLE IF NOT EXISTS demo_points_backup (
    id BIGINT,
    geom GEOMETRY(Point, 3857),
    demo_tag TEXT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    snapshot_id TEXT,
    PRIMARY KEY (id, snapshot_id)
);

CREATE TABLE IF NOT EXISTS demo_lines_backup (
    id BIGINT,
    geom GEOMETRY(LineString, 3857),
    demo_tag TEXT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    snapshot_id TEXT,
    PRIMARY KEY (id, snapshot_id)
);

CREATE TABLE IF NOT EXISTS demo_polygons_backup (
    id BIGINT,
    geom GEOMETRY(Polygon, 3857),
    demo_tag TEXT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    snapshot_id TEXT,
    PRIMARY KEY (id, snapshot_id)
);

-- Indexes for backup tables
CREATE INDEX IF NOT EXISTS idx_demo_points_backup_snapshot ON demo_points_backup (snapshot_id);
CREATE INDEX IF NOT EXISTS idx_demo_lines_backup_snapshot ON demo_lines_backup (snapshot_id);
CREATE INDEX IF NOT EXISTS idx_demo_polygons_backup_snapshot ON demo_polygons_backup (snapshot_id);

-----------------------------------------------------------------------
--  Function: create_geometry_snapshot()
--  Creates a snapshot of current geometry state for later restoration
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION create_geometry_snapshot(
    snapshot_name TEXT DEFAULT NULL,
    is_baseline BOOLEAN DEFAULT FALSE
)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    snapshot_id TEXT;
    points_count INT;
    lines_count INT;
    polygons_count INT;
BEGIN
    -- Generate snapshot ID
    IF snapshot_name IS NULL THEN
        snapshot_id := 'snapshot_' || extract(epoch FROM now())::BIGINT || '_' || floor(random() * 1000)::INT;
    ELSE
        snapshot_id := snapshot_name;
    END IF;
    
    RAISE NOTICE 'Creating geometry snapshot: %', snapshot_id;
    
    -- Backup current points
    INSERT INTO demo_points_backup (id, geom, demo_tag, created_at, updated_at, snapshot_id)
    SELECT id, geom, demo_tag, created_at, updated_at, snapshot_id
    FROM demo_points;
    
    GET DIAGNOSTICS points_count = ROW_COUNT;
    
    -- Backup current lines
    INSERT INTO demo_lines_backup (id, geom, demo_tag, created_at, updated_at, snapshot_id)
    SELECT id, geom, demo_tag, created_at, updated_at, snapshot_id
    FROM demo_lines;
    
    GET DIAGNOSTICS lines_count = ROW_COUNT;
    
    -- Backup current polygons
    INSERT INTO demo_polygons_backup (id, geom, demo_tag, created_at, updated_at, snapshot_id)
    SELECT id, geom, demo_tag, created_at, updated_at, snapshot_id
    FROM demo_polygons;
    
    GET DIAGNOSTICS polygons_count = ROW_COUNT;
    
    -- Record snapshot metadata
    INSERT INTO geometry_snapshots (id, points_count, lines_count, polygons_count, is_baseline)
    VALUES (snapshot_id, points_count, lines_count, polygons_count, is_baseline);
    
    RAISE NOTICE 'Snapshot % created: % points, % lines, % polygons', 
                 snapshot_id, points_count, lines_count, polygons_count;
    
    RETURN snapshot_id;
END;
$$;

-----------------------------------------------------------------------
--  Function: restore_geometry_snapshot()
--  Restores geometry state from a specific snapshot
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION restore_geometry_snapshot(
    snapshot_id TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
DECLARE
    snapshot_exists BOOLEAN;
    points_restored INT;
    lines_restored INT;
    polygons_restored INT;
BEGIN
    -- Check if snapshot exists
    SELECT EXISTS(SELECT 1 FROM geometry_snapshots WHERE id = snapshot_id) INTO snapshot_exists;
    
    IF NOT snapshot_exists THEN
        RAISE WARNING 'Snapshot % does not exist', snapshot_id;
        RETURN FALSE;
    END IF;
    
    RAISE NOTICE 'Restoring geometry from snapshot: %', snapshot_id;
    
    -- Disable triggers during restoration to avoid change tracking
    SET session_replication_role = replica;
    
    BEGIN
        -- Clear current geometry data
        TRUNCATE TABLE demo_points CASCADE;
        TRUNCATE TABLE demo_lines CASCADE;
        TRUNCATE TABLE demo_polygons CASCADE;
        
        -- Restore points from snapshot
        INSERT INTO demo_points (id, geom, demo_tag, created_at, updated_at)
        SELECT id, geom, demo_tag, created_at, updated_at
        FROM demo_points_backup
        WHERE demo_points_backup.snapshot_id = restore_geometry_snapshot.snapshot_id;
        
        GET DIAGNOSTICS points_restored = ROW_COUNT;
        
        -- Restore lines from snapshot
        INSERT INTO demo_lines (id, geom, demo_tag, created_at, updated_at)
        SELECT id, geom, demo_tag, created_at, updated_at
        FROM demo_lines_backup
        WHERE demo_lines_backup.snapshot_id = restore_geometry_snapshot.snapshot_id;
        
        GET DIAGNOSTICS lines_restored = ROW_COUNT;
        
        -- Restore polygons from snapshot
        INSERT INTO demo_polygons (id, geom, demo_tag, created_at, updated_at)
        SELECT id, geom, demo_tag, created_at, updated_at
        FROM demo_polygons_backup
        WHERE demo_polygons_backup.snapshot_id = restore_geometry_snapshot.snapshot_id;
        
        GET DIAGNOSTICS polygons_restored = ROW_COUNT;
        
        -- Update sequences to avoid ID conflicts
        PERFORM setval('demo_points_id_seq', COALESCE((SELECT MAX(id) FROM demo_points), 0) + 1, false);
        PERFORM setval('demo_lines_id_seq', COALESCE((SELECT MAX(id) FROM demo_lines), 0) + 1, false);
        PERFORM setval('demo_polygons_id_seq', COALESCE((SELECT MAX(id) FROM demo_polygons), 0) + 1, false);
        
        -- Re-enable triggers
        SET session_replication_role = DEFAULT;
        
        RAISE NOTICE 'Snapshot % restored: % points, % lines, % polygons', 
                     snapshot_id, points_restored, lines_restored, polygons_restored;
        
        RETURN TRUE;
        
    EXCEPTION WHEN OTHERS THEN
        -- Re-enable triggers on error
        SET session_replication_role = DEFAULT;
        RAISE;
    END;
END;
$$;

-----------------------------------------------------------------------
--  Function: reset_simulation_state()
--  Main function to reset simulation state and restore original data
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reset_simulation_state(
    use_snapshot_id TEXT DEFAULT NULL
)
RETURNS TABLE (
    success BOOLEAN,
    message TEXT,
    points_restored INT,
    lines_restored INT,
    polygons_restored INT,
    tiles_cleared INT
)
LANGUAGE plpgsql AS $$
DECLARE
    target_snapshot_id TEXT;
    baseline_snapshot TEXT;
    restoration_success BOOLEAN;
    tiles_cleared_count INT;
    points_count INT;
    lines_count INT;
    polygons_count INT;
BEGIN
    RAISE NOTICE 'Starting simulation state reset...';
    
    -- Determine which snapshot to use
    IF use_snapshot_id IS NOT NULL THEN
        target_snapshot_id := use_snapshot_id;
        RAISE NOTICE 'Using specified snapshot: %', target_snapshot_id;
    ELSE
        -- Find the most recent baseline snapshot
        SELECT gs.id INTO baseline_snapshot
        FROM geometry_snapshots gs
        WHERE gs.is_baseline = TRUE
        ORDER BY gs.created_at DESC
        LIMIT 1;
        
        IF baseline_snapshot IS NULL THEN
            -- No baseline snapshot exists, create one from current state if it looks like original data
            SELECT COUNT(*) INTO points_count FROM demo_points WHERE demo_tag LIKE 'tile_%_point_%';
            SELECT COUNT(*) INTO lines_count FROM demo_lines WHERE demo_tag LIKE 'tile_%_line';
            SELECT COUNT(*) INTO polygons_count FROM demo_polygons WHERE demo_tag LIKE 'tile_%_polygon';
            
            -- If we have the expected original data pattern, create baseline snapshot
            IF points_count > 0 AND lines_count > 0 AND polygons_count > 0 THEN
                target_snapshot_id := create_geometry_snapshot('baseline_auto_' || extract(epoch FROM now())::BIGINT, TRUE);
                RAISE NOTICE 'Created automatic baseline snapshot: %', target_snapshot_id;
            ELSE
                success := FALSE;
                message := 'No baseline snapshot found and current data does not appear to be original demo data';
                points_restored := 0;
                lines_restored := 0;
                polygons_restored := 0;
                tiles_cleared := 0;
                RETURN NEXT;
                RETURN;
            END IF;
        ELSE
            target_snapshot_id := baseline_snapshot;
            RAISE NOTICE 'Using baseline snapshot: %', target_snapshot_id;
        END IF;
    END IF;
    
    -- Clear all changed tiles to prevent interference with previous simulation results
    DELETE FROM changed_tiles;
    GET DIAGNOSTICS tiles_cleared_count = ROW_COUNT;
    
    -- Restore geometry from snapshot
    SELECT restore_geometry_snapshot(target_snapshot_id) INTO restoration_success;
    
    IF restoration_success THEN
        -- Get counts of restored data
        SELECT COUNT(*) INTO points_count FROM demo_points;
        SELECT COUNT(*) INTO lines_count FROM demo_lines;
        SELECT COUNT(*) INTO polygons_count FROM demo_polygons;
        
        -- Mark any active simulation sessions as completed
        UPDATE simulation_sessions 
        SET status = 'reset', completed_at = NOW()
        WHERE status IN ('starting', 'processing');
        
        success := TRUE;
        message := format('Simulation state reset successfully using snapshot %s', target_snapshot_id);
        points_restored := points_count;
        lines_restored := lines_count;
        polygons_restored := polygons_count;
        tiles_cleared := tiles_cleared_count;
        
        RAISE NOTICE 'Simulation state reset complete: % points, % lines, % polygons restored, % tiles cleared',
                     points_count, lines_count, polygons_count, tiles_cleared_count;
    ELSE
        success := FALSE;
        message := format('Failed to restore from snapshot %s', target_snapshot_id);
        points_restored := 0;
        lines_restored := 0;
        polygons_restored := 0;
        tiles_cleared := tiles_cleared_count;
    END IF;
    
    RETURN NEXT;
END;
$$;

-----------------------------------------------------------------------
--  Function: cleanup_old_snapshots()
--  Removes old snapshots to prevent storage bloat
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cleanup_old_snapshots(
    keep_count INT DEFAULT 5,
    keep_baseline BOOLEAN DEFAULT TRUE
)
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
    snapshots_to_delete TEXT[];
    snapshot_id TEXT;
    deleted_count INT := 0;
BEGIN
    -- Find snapshots to delete (keep most recent ones, always keep baseline)
    SELECT ARRAY(
        SELECT gs.id
        FROM geometry_snapshots gs
        WHERE (NOT keep_baseline OR gs.is_baseline = FALSE)
        ORDER BY gs.created_at DESC
        OFFSET keep_count
    ) INTO snapshots_to_delete;
    
    -- Delete old snapshots
    FOREACH snapshot_id IN ARRAY snapshots_to_delete LOOP
        DELETE FROM demo_points_backup WHERE demo_points_backup.snapshot_id = cleanup_old_snapshots.snapshot_id;
        DELETE FROM demo_lines_backup WHERE demo_lines_backup.snapshot_id = cleanup_old_snapshots.snapshot_id;
        DELETE FROM demo_polygons_backup WHERE demo_polygons_backup.snapshot_id = cleanup_old_snapshots.snapshot_id;
        DELETE FROM geometry_snapshots WHERE id = cleanup_old_snapshots.snapshot_id;
        
        deleted_count := deleted_count + 1;
        RAISE NOTICE 'Deleted snapshot: %', snapshot_id;
    END LOOP;
    
    RAISE NOTICE 'Cleaned up % old snapshots', deleted_count;
    RETURN deleted_count;
END;
$$;

-----------------------------------------------------------------------
--  Function: get_simulation_state_info()
--  Returns information about current simulation state and available snapshots
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_simulation_state_info()
RETURNS TABLE (
    active_sessions INT,
    available_snapshots INT,
    baseline_snapshots INT,
    current_points INT,
    current_lines INT,
    current_polygons INT,
    simulation_generated_points INT
)
LANGUAGE plpgsql AS $$
DECLARE
    active_count INT;
    snapshot_count INT;
    baseline_count INT;
    points_count INT;
    lines_count INT;
    polygons_count INT;
    sim_points_count INT;
BEGIN
    -- Count active simulation sessions
    SELECT COUNT(*) INTO active_count
    FROM simulation_sessions
    WHERE status IN ('starting', 'processing');
    
    -- Count available snapshots
    SELECT COUNT(*) INTO snapshot_count FROM geometry_snapshots;
    SELECT COUNT(*) INTO baseline_count FROM geometry_snapshots WHERE is_baseline = TRUE;
    
    -- Count current geometry
    SELECT COUNT(*) INTO points_count FROM demo_points;
    SELECT COUNT(*) INTO lines_count FROM demo_lines;
    SELECT COUNT(*) INTO polygons_count FROM demo_polygons;
    
    -- Count simulation-generated points (those with sim_ prefix)
    SELECT COUNT(*) INTO sim_points_count FROM demo_points WHERE demo_tag LIKE 'sim_%';
    
    active_sessions := active_count;
    available_snapshots := snapshot_count;
    baseline_snapshots := baseline_count;
    current_points := points_count;
    current_lines := lines_count;
    current_polygons := polygons_count;
    simulation_generated_points := sim_points_count;
    
    RETURN NEXT;
END;
$$;

-----------------------------------------------------------------------
--  Function: recover_from_incomplete_simulation()
--  Detects and recovers from incomplete simulations on startup
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION recover_from_incomplete_simulation()
RETURNS TABLE (
    recovery_needed BOOLEAN,
    recovery_action TEXT,
    sessions_cleaned INT
)
LANGUAGE plpgsql AS $$
DECLARE
    incomplete_sessions INT;
    cleaned_sessions INT := 0;
    recovery_performed BOOLEAN := FALSE;
    action_taken TEXT := 'none';
BEGIN
    -- Check for incomplete simulation sessions
    SELECT COUNT(*) INTO incomplete_sessions
    FROM simulation_sessions
    WHERE status IN ('starting', 'processing')
      AND started_at < NOW() - INTERVAL '1 hour'; -- Consider sessions older than 1 hour as stuck
    
    IF incomplete_sessions > 0 THEN
        RAISE NOTICE 'Found % incomplete simulation sessions, performing recovery...', incomplete_sessions;
        
        -- Mark stuck sessions as failed
        UPDATE simulation_sessions
        SET status = 'failed', completed_at = NOW()
        WHERE status IN ('starting', 'processing')
          AND started_at < NOW() - INTERVAL '1 hour';
        
        GET DIAGNOSTICS cleaned_sessions = ROW_COUNT;
        
        -- Reset simulation state to clean baseline
        PERFORM reset_simulation_state();
        
        recovery_performed := TRUE;
        action_taken := format('Reset to baseline, marked %s sessions as failed', cleaned_sessions);
        
        RAISE NOTICE 'Recovery complete: % sessions cleaned, state reset to baseline', cleaned_sessions;
    ELSE
        RAISE NOTICE 'No incomplete simulation sessions found, no recovery needed';
    END IF;
    
    recovery_needed := recovery_performed;
    recovery_action := action_taken;
    sessions_cleaned := cleaned_sessions;
    
    RETURN NEXT;
END;
$$;

-----------------------------------------------------------------------
--  Initialize baseline snapshot if none exists
-----------------------------------------------------------------------
DO $$
BEGIN
    -- Check if we have any baseline snapshots
    IF NOT EXISTS (SELECT 1 FROM geometry_snapshots WHERE is_baseline = TRUE) THEN
        -- Check if we have demo data that looks like original baseline
        IF EXISTS (
            SELECT 1 FROM demo_points dp
            JOIN demo_lines dl ON TRUE
            JOIN demo_polygons dpg ON TRUE
            WHERE dp.demo_tag LIKE 'tile_%_point_%'
              AND dl.demo_tag LIKE 'tile_%_line'
              AND dpg.demo_tag LIKE 'tile_%_polygon'
            LIMIT 1
        ) THEN
            PERFORM create_geometry_snapshot('initial_baseline', TRUE);
            RAISE NOTICE 'Created initial baseline snapshot from existing demo data';
        END IF;
    END IF;
END;
$$;

-----------------------------------------------------------------------
--  Function: reset_synthetic_demo()
--  Simple function to reset demo data (called by initial data script)
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reset_synthetic_demo()
RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
    -- This function is called during initial data setup
    -- For now, just ensure we have a clean state
    PERFORM reset_simulation_state();
    RAISE NOTICE 'Synthetic demo reset completed';
END;
$$;

-----------------------------------------------------------------------
--  Completion notice
-----------------------------------------------------------------------
SELECT 'Simulation state reset functionality installed successfully' AS status;