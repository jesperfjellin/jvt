-- Integration tests for simulation state management database functions
-- These can be run directly in PostgreSQL to verify the implementation

-- Test 1: Basic simulation session creation
DO $$
DECLARE
    result RECORD;
    session_uuid UUID;
    success_flag BOOLEAN;
    message_text TEXT;
BEGIN
    -- Cleanup any existing test sessions
    UPDATE simulation_sessions SET status = 'test_cleanup', completed_at = NOW() 
    WHERE status IN ('starting', 'processing');
    
    -- Test session creation
    SELECT * INTO result FROM create_simulation_session(0.05, 12345, 60, 'test_user');
    session_uuid := result.session_id;
    success_flag := result.success;
    message_text := result.message;
    
    IF NOT success_flag THEN
        RAISE EXCEPTION 'Session creation failed: %', message_text;
    END IF;
    
    IF session_uuid IS NULL THEN
        RAISE EXCEPTION 'Session ID should not be null';
    END IF;
    
    RAISE NOTICE 'Test 1 PASSED: Basic simulation session creation works';
END $$;

-- Test 2: Concurrent simulation prevention
DO $$
DECLARE
    first_result RECORD;
    second_result RECORD;
    first_success BOOLEAN;
    second_success BOOLEAN;
    second_message TEXT;
BEGIN
    -- Cleanup any existing test sessions
    UPDATE simulation_sessions SET status = 'test_cleanup', completed_at = NOW() 
    WHERE status IN ('starting', 'processing');
    
    -- Create first session (should succeed)
    SELECT * INTO first_result FROM create_simulation_session(0.10, 12345, 60, 'test_user1');
    first_success := first_result.success;
    
    IF NOT first_success THEN
        RAISE EXCEPTION 'First session creation should succeed';
    END IF;
    
    -- Try to create second session (should fail)
    SELECT * INTO second_result FROM create_simulation_session(0.10, 12346, 60, 'test_user2');
    second_success := second_result.success;
    second_message := second_result.message;
    
    IF second_success THEN
        RAISE EXCEPTION 'Second session creation should fail';
    END IF;
    
    IF second_message NOT LIKE '%active simulation%' THEN
        RAISE EXCEPTION 'Error message should mention active simulation: %', second_message;
    END IF;
    
    RAISE NOTICE 'Test 2 PASSED: Concurrent simulation prevention works';
END $$;

-- Test 3: Simulation status functions
DO $$
DECLARE
    is_running_initial BOOLEAN;
    is_running_after BOOLEAN;
    active_count_initial INT;
    active_count_after INT;
    session_result RECORD;
BEGIN
    -- Cleanup any existing test sessions
    UPDATE simulation_sessions SET status = 'test_cleanup', completed_at = NOW() 
    WHERE status IN ('starting', 'processing');
    
    -- Check initial status (should be false)
    SELECT is_simulation_running() INTO is_running_initial;
    SELECT COUNT(*) INTO active_count_initial FROM get_active_simulation_sessions();
    
    IF is_running_initial THEN
        RAISE EXCEPTION 'No simulation should be running initially';
    END IF;
    
    IF active_count_initial != 0 THEN
        RAISE EXCEPTION 'No active sessions should exist initially';
    END IF;
    
    -- Create a session
    SELECT * INTO session_result FROM create_simulation_session(0.05, 12345, 60, 'test_user');
    
    IF NOT session_result.success THEN
        RAISE EXCEPTION 'Session creation should succeed';
    END IF;
    
    -- Check status after session creation
    SELECT is_simulation_running() INTO is_running_after;
    SELECT COUNT(*) INTO active_count_after FROM get_active_simulation_sessions();
    
    IF NOT is_running_after THEN
        RAISE EXCEPTION 'Simulation should be running after session creation';
    END IF;
    
    IF active_count_after != 1 THEN
        RAISE EXCEPTION 'One active session should exist, found: %', active_count_after;
    END IF;
    
    RAISE NOTICE 'Test 3 PASSED: Simulation status functions work correctly';
END $$;

-- Test 4: Simulation state reset
DO $$
DECLARE
    first_result RECORD;
    second_result RECORD;
    reset_result RECORD;
    first_tiles INT;
    second_tiles INT;
    reset_success BOOLEAN;
BEGIN
    -- Cleanup any existing test sessions
    UPDATE simulation_sessions SET status = 'test_cleanup', completed_at = NOW() 
    WHERE status IN ('starting', 'processing');
    
    -- Run first simulation
    SELECT * INTO first_result FROM simulate_tile_changes(8, 0.05, 12345);
    first_tiles := first_result.selected_tiles;
    
    IF first_tiles <= 0 THEN
        RAISE EXCEPTION 'First simulation should process some tiles';
    END IF;
    
    -- Reset simulation state
    SELECT * INTO reset_result FROM reset_simulation_state();
    reset_success := reset_result.success;
    
    IF NOT reset_success THEN
        RAISE EXCEPTION 'Reset should succeed: %', reset_result.message;
    END IF;
    
    -- Run second simulation with same parameters
    SELECT * INTO second_result FROM simulate_tile_changes(8, 0.05, 12345);
    second_tiles := second_result.selected_tiles;
    
    -- Verify both simulations processed the same number of tiles
    IF first_tiles != second_tiles THEN
        RAISE EXCEPTION 'Both simulations should process the same number of tiles: % vs %', first_tiles, second_tiles;
    END IF;
    
    RAISE NOTICE 'Test 4 PASSED: Simulation state reset works correctly';
END $$;

-- Test 5: Session lifecycle management
DO $$
DECLARE
    session_result RECORD;
    session_uuid UUID;
    update_success BOOLEAN;
    cleanup_success BOOLEAN;
    is_running_after BOOLEAN;
BEGIN
    -- Cleanup any existing test sessions
    UPDATE simulation_sessions SET status = 'test_cleanup', completed_at = NOW() 
    WHERE status IN ('starting', 'processing');
    
    -- Create session
    SELECT * INTO session_result FROM create_simulation_session(0.05, 12345, 60, 'test_user');
    session_uuid := session_result.session_id;
    
    IF NOT session_result.success THEN
        RAISE EXCEPTION 'Session creation should succeed';
    END IF;
    
    -- Update session to processing
    SELECT update_simulation_session(session_uuid, 'processing') INTO update_success;
    
    IF NOT update_success THEN
        RAISE EXCEPTION 'Session update should succeed';
    END IF;
    
    -- Cleanup session as completed
    SELECT cleanup_simulation_session(session_uuid, 'completed') INTO cleanup_success;
    
    IF NOT cleanup_success THEN
        RAISE EXCEPTION 'Session cleanup should succeed';
    END IF;
    
    -- Verify no simulation is running
    SELECT is_simulation_running() INTO is_running_after;
    
    IF is_running_after THEN
        RAISE EXCEPTION 'No simulation should be running after cleanup';
    END IF;
    
    RAISE NOTICE 'Test 5 PASSED: Session lifecycle management works correctly';
END $$;

-- Final cleanup
UPDATE simulation_sessions SET status = 'test_cleanup', completed_at = NOW() 
WHERE status IN ('starting', 'processing');

SELECT 'All simulation state management tests completed successfully!' AS test_result;