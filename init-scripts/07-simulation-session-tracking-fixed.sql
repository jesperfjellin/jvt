/***********************************************************************
  07-simulation-session-tracking-fixed.sql
  ----------------------------------------------------------------------
  Enhanced simulation session tracking functionality for JVT demo.
  
  This provides mechanisms to:
  • Track active simulations with proper session management
  • Implement session-based locking to prevent concurrent simulations
  • Add session timeout and cleanup mechanisms
  • Provide functions to create, update, and cleanup simulation sessions
***********************************************************************/

-----------------------------------------------------------------------
--  Enhanced simulation_sessions table (add missing columns to existing table)
-----------------------------------------------------------------------
-- Add missing columns to existing simulation_sessions table
ALTER TABLE simulation_sessions 
ADD COLUMN IF NOT EXISTS timeout_at TIMESTAMPTZ DEFAULT (NOW() + INTERVAL '1 hour'),
ADD COLUMN IF NOT EXISTS created_by TEXT DEFAULT 'system',
ADD COLUMN IF NOT EXISTS last_heartbeat TIMESTAMPTZ DEFAULT NOW();

-- Add indexes for efficient session queries
CREATE INDEX IF NOT EXISTS idx_simulation_sessions_timeout ON simulation_sessions (timeout_at) WHERE status IN ('starting', 'processing');
CREATE INDEX IF NOT EXISTS idx_simulation_sessions_heartbeat ON simulation_sessions (last_heartbeat) WHERE status IN ('starting', 'processing');

-----------------------------------------------------------------------
--  Function: create_simulation_session()
--  Creates a new simulation session with proper locking checks
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION create_simulation_session(
    p_percentage FLOAT8,
    p_seed_value INT DEFAULT 12345,
    p_timeout_minutes INT DEFAULT 60,
    p_created_by TEXT DEFAULT 'system'
)
RETURNS TABLE (
    session_id UUID,
    success BOOLEAN,
    message TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    new_session_id UUID;
    active_count INT;
    cleanup_count INT;
BEGIN
    -- First, cleanup any expired sessions
    SELECT cleanup_expired_sessions() INTO cleanup_count;
    
    IF cleanup_count > 0 THEN
        RAISE NOTICE 'Cleaned up % expired simulation sessions', cleanup_count;
    END IF;
    
    -- Check for active simulations (session-based locking)
    SELECT COUNT(*) INTO active_count
    FROM simulation_sessions
    WHERE status IN ('starting', 'processing')
      AND timeout_at > NOW();
    
    IF active_count > 0 THEN
        -- Return failure - concurrent simulation detected
        session_id := NULL;
        success := FALSE;
        message := format('Cannot start simulation: %s active simulation(s) already running', active_count);
        RETURN NEXT;
        RETURN;
    END IF;
    
    -- Create new simulation session
    INSERT INTO simulation_sessions (
        percentage,
        seed_value,
        timeout_at,
        created_by,
        status
    )
    VALUES (
        p_percentage,
        p_seed_value,
        NOW() + (p_timeout_minutes || ' minutes')::INTERVAL,
        p_created_by,
        'starting'
    )
    RETURNING id INTO new_session_id;
    
    -- Return success
    session_id := new_session_id;
    success := TRUE;
    message := format('Simulation session %s created successfully', new_session_id);
    
    RAISE NOTICE 'Created simulation session %s (%.1f%%, seed: %s, timeout: %s minutes)', 
                 new_session_id, p_percentage * 100, p_seed_value, p_timeout_minutes;
    
    RETURN NEXT;
END;
$$;

-----------------------------------------------------------------------
--  Function: update_simulation_session()
--  Updates simulation session status and heartbeat
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_simulation_session(
    p_session_id UUID,
    p_status TEXT DEFAULT NULL,
    p_heartbeat BOOLEAN DEFAULT TRUE
)
RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
DECLARE
    session_exists BOOLEAN;
    old_status TEXT;
BEGIN
    -- Check if session exists and get current status
    SELECT EXISTS(SELECT 1 FROM simulation_sessions WHERE id = p_session_id),
           status
    INTO session_exists, old_status
    FROM simulation_sessions
    WHERE id = p_session_id;
    
    IF NOT session_exists THEN
        RAISE WARNING 'Simulation session % does not exist', p_session_id;
        RETURN FALSE;
    END IF;
    
    -- Update session
    UPDATE simulation_sessions
    SET 
        status = COALESCE(p_status, status),
        last_heartbeat = CASE WHEN p_heartbeat THEN NOW() ELSE last_heartbeat END,
        completed_at = CASE WHEN p_status IN ('completed', 'failed', 'cancelled', 'reset') 
                           THEN NOW() 
                           ELSE completed_at END
    WHERE id = p_session_id;
    
    IF p_status IS NOT NULL AND p_status != old_status THEN
        RAISE NOTICE 'Simulation session % status changed: % -> %', p_session_id, old_status, p_status;
    END IF;
    
    RETURN TRUE;
END;
$$;

-----------------------------------------------------------------------
--  Function: cleanup_simulation_session()
--  Properly cleanup a specific simulation session
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cleanup_simulation_session(
    p_session_id UUID,
    p_final_status TEXT DEFAULT 'completed'
)
RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
DECLARE
    session_exists BOOLEAN;
    session_snapshot TEXT;
BEGIN
    -- Check if session exists and get snapshot info
    SELECT EXISTS(SELECT 1 FROM simulation_sessions WHERE id = p_session_id),
           snapshot_id
    INTO session_exists, session_snapshot
    FROM simulation_sessions
    WHERE id = p_session_id;
    
    IF NOT session_exists THEN
        RAISE WARNING 'Simulation session % does not exist', p_session_id;
        RETURN FALSE;
    END IF;
    
    -- Update session to final status
    UPDATE simulation_sessions
    SET 
        status = p_final_status,
        completed_at = NOW()
    WHERE id = p_session_id;
    
    -- Optional: cleanup associated snapshot if it's not a baseline
    IF session_snapshot IS NOT NULL THEN
        -- Only cleanup non-baseline snapshots
        IF NOT EXISTS (
            SELECT 1 FROM geometry_snapshots 
            WHERE id = session_snapshot AND is_baseline = TRUE
        ) THEN
            DELETE FROM demo_points_backup WHERE snapshot_id = session_snapshot;
            DELETE FROM demo_lines_backup WHERE snapshot_id = session_snapshot;
            DELETE FROM demo_polygons_backup WHERE snapshot_id = session_snapshot;
            DELETE FROM geometry_snapshots WHERE id = session_snapshot;
            
            RAISE NOTICE 'Cleaned up snapshot % for session %', session_snapshot, p_session_id;
        END IF;
    END IF;
    
    RAISE NOTICE 'Simulation session % cleaned up with status: %', p_session_id, p_final_status;
    RETURN TRUE;
END;
$$;

-----------------------------------------------------------------------
--  Function: cleanup_expired_sessions()
--  Cleanup sessions that have exceeded their timeout
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cleanup_expired_sessions()
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
    expired_sessions UUID[];
    session_id UUID;
    cleanup_count INT := 0;
BEGIN
    -- Find expired sessions
    SELECT ARRAY(
        SELECT id
        FROM simulation_sessions
        WHERE status IN ('starting', 'processing')
          AND (timeout_at < NOW() OR last_heartbeat < NOW() - INTERVAL '30 minutes')
    ) INTO expired_sessions;
    
    -- Cleanup each expired session
    FOREACH session_id IN ARRAY expired_sessions LOOP
        PERFORM cleanup_simulation_session(session_id, 'timeout');
        cleanup_count := cleanup_count + 1;
    END LOOP;
    
    IF cleanup_count > 0 THEN
        RAISE NOTICE 'Cleaned up % expired simulation sessions', cleanup_count;
    END IF;
    
    RETURN cleanup_count;
END;
$$;

-----------------------------------------------------------------------
--  Function: get_active_simulation_sessions()
--  Returns information about currently active simulation sessions
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_active_simulation_sessions()
RETURNS TABLE (
    session_id UUID,
    percentage FLOAT8,
    status TEXT,
    started_at TIMESTAMPTZ,
    timeout_at TIMESTAMPTZ,
    created_by TEXT,
    minutes_running INT,
    minutes_until_timeout INT
)
LANGUAGE sql AS $$
    SELECT 
        id,
        percentage,
        status,
        started_at,
        timeout_at,
        created_by,
        EXTRACT(EPOCH FROM (NOW() - started_at))::INT / 60 AS minutes_running,
        EXTRACT(EPOCH FROM (timeout_at - NOW()))::INT / 60 AS minutes_until_timeout
    FROM simulation_sessions
    WHERE status IN ('starting', 'processing')
      AND timeout_at > NOW()
    ORDER BY started_at;
$$;

-----------------------------------------------------------------------
--  Function: is_simulation_running()
--  Simple check if any simulation is currently running
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION is_simulation_running()
RETURNS BOOLEAN
LANGUAGE sql AS $$
    SELECT EXISTS(
        SELECT 1 
        FROM simulation_sessions 
        WHERE status IN ('starting', 'processing')
          AND timeout_at > NOW()
    );
$$;

-----------------------------------------------------------------------
--  Function: cancel_simulation_session()
--  Cancel a running simulation session
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cancel_simulation_session(
    p_session_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
DECLARE
    session_status TEXT;
BEGIN
    -- Get current session status
    SELECT status INTO session_status
    FROM simulation_sessions
    WHERE id = p_session_id;
    
    IF session_status IS NULL THEN
        RAISE WARNING 'Simulation session % does not exist', p_session_id;
        RETURN FALSE;
    END IF;
    
    IF session_status NOT IN ('starting', 'processing') THEN
        RAISE WARNING 'Cannot cancel simulation session % - current status: %', p_session_id, session_status;
        RETURN FALSE;
    END IF;
    
    -- Cancel the session
    PERFORM cleanup_simulation_session(p_session_id, 'cancelled');
    
    RAISE NOTICE 'Simulation session % has been cancelled', p_session_id;
    RETURN TRUE;
END;
$$;

-----------------------------------------------------------------------
--  Function: get_simulation_session_info()
--  Get detailed information about a specific simulation session
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_simulation_session_info(
    p_session_id UUID
)
RETURNS TABLE (
    session_id UUID,
    percentage FLOAT8,
    status TEXT,
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    timeout_at TIMESTAMPTZ,
    created_by TEXT,
    seed_value INT,
    snapshot_id TEXT,
    duration_minutes INT,
    is_expired BOOLEAN
)
LANGUAGE sql AS $$
    SELECT 
        id,
        percentage,
        status,
        started_at,
        completed_at,
        timeout_at,
        created_by,
        seed_value,
        snapshot_id,
        CASE 
            WHEN completed_at IS NOT NULL THEN 
                EXTRACT(EPOCH FROM (completed_at - started_at))::INT / 60
            ELSE 
                EXTRACT(EPOCH FROM (NOW() - started_at))::INT / 60
        END AS duration_minutes,
        (timeout_at < NOW() AND status IN ('starting', 'processing')) AS is_expired
    FROM simulation_sessions
    WHERE id = p_session_id;
$$;

-----------------------------------------------------------------------
--  Function: cleanup_old_simulation_sessions()
--  Remove old completed simulation sessions to prevent table bloat
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cleanup_old_simulation_sessions(
    p_keep_days INT DEFAULT 7
)
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
    deleted_count INT;
BEGIN
    -- Delete old completed sessions
    DELETE FROM simulation_sessions
    WHERE status IN ('completed', 'failed', 'cancelled', 'timeout', 'reset')
      AND completed_at < NOW() - (p_keep_days || ' days')::INTERVAL;
    
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    
    IF deleted_count > 0 THEN
        RAISE NOTICE 'Cleaned up % old simulation sessions (older than % days)', deleted_count, p_keep_days;
    END IF;
    
    RETURN deleted_count;
END;
$$;

-----------------------------------------------------------------------
--  Automatic cleanup job setup (can be called periodically)
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION perform_session_maintenance()
RETURNS TABLE (
    expired_sessions_cleaned INT,
    old_sessions_cleaned INT,
    active_sessions_count INT
)
LANGUAGE plpgsql AS $$
DECLARE
    expired_count INT;
    old_count INT;
    active_count INT;
BEGIN
    -- Cleanup expired sessions
    SELECT cleanup_expired_sessions() INTO expired_count;
    
    -- Cleanup old completed sessions
    SELECT cleanup_old_simulation_sessions() INTO old_count;
    
    -- Count remaining active sessions
    SELECT COUNT(*) INTO active_count
    FROM simulation_sessions
    WHERE status IN ('starting', 'processing')
      AND timeout_at > NOW();
    
    expired_sessions_cleaned := expired_count;
    old_sessions_cleaned := old_count;
    active_sessions_count := active_count;
    
    RETURN NEXT;
END;
$$;

-----------------------------------------------------------------------
--  Completion notice
-----------------------------------------------------------------------
SELECT 'Simulation session tracking functionality installed successfully' AS status;