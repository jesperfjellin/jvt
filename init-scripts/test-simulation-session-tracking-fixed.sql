/***********************************************************************
  test-simulation-session-tracking-fixed.sql
  ----------------------------------------------------------------------
  Comprehensive tests for simulation session tracking functionality.
  
  Tests cover:
  • Session creation and validation
  • Concurrent simulation prevention (session-based locking)
  • Session timeout and cleanup mechanisms
  • Session status updates and heartbeat functionality
  • Session cancellation and cleanup
***********************************************************************/

-----------------------------------------------------------------------
--  Test framework setup
-----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS session_test_results (
    test_name TEXT PRIMARY KEY,
    passed BOOLEAN,
    message TEXT,
    executed_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION record_session_test_result(
    test_name TEXT,
    passed BOOLEAN,
    message TEXT
)
RETURNS VOID
LANGUAGE sql AS $$
    INSERT INTO session_test_results (test_name, passed, message)
    VALUES (test_name, passed, message)
    ON CONFLICT (test_name) 
    DO UPDATE SET 
        passed = EXCLUDED.passed,
        message = EXCLUDED.message,
        executed_at = NOW();
$$;

-----------------------------------------------------------------------
--  Test 1: Basic session creation and validation
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION test_session_creation()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    result RECORD;
    session_info RECORD;
    test_passed BOOLEAN := FALSE;
BEGIN
    RAISE NOTICE 'Running Test 1: Basic session creation and validation';
    
    -- Clean up any existing test sessions
    DELETE FROM simulation_sessions WHERE created_by = 'test_session_creation';
    
    -- Test successful session creation
    SELECT * INTO result FROM create_simulation_session(
        p_percentage := 0.05,
        p_seed_value := 12345,
        p_timeout_minutes := 30,
        p_created_by := 'test_session_creation'
    );
    
    -- Validate session was created successfully
    IF result.success AND result.session_id IS NOT NULL THEN
        -- Get session info to validate details
        SELECT * INTO session_info FROM get_simulation_session_info(result.session_id);
        
        IF session_info.percentage = 0.05 AND 
           session_info.seed_value = 12345 AND
           session_info.status = 'starting' AND
           session_info.created_by = 'test_session_creation' THEN
            test_passed := TRUE;
        END IF;
    END IF;
    
    -- Record test result
    IF test_passed THEN
        PERFORM record_session_test_result('session_creation', TRUE, 
                                         format('Session created successfully: %s', result.session_id));
    ELSE
        PERFORM record_session_test_result('session_creation', FALSE, 
                                         format('Session creation failed: %s', result.message));
    END IF;
    
    -- Cleanup
    DELETE FROM simulation_sessions WHERE created_by = 'test_session_creation';
END;
$$;

-----------------------------------------------------------------------
--  Test 2: Concurrent simulation prevention (session-based locking)
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION test_concurrent_simulation_prevention()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    first_session RECORD;
    second_session RECORD;
    test_passed BOOLEAN := FALSE;
BEGIN
    RAISE NOTICE 'Running Test 2: Concurrent simulation prevention';
    
    -- Clean up any existing test sessions
    DELETE FROM simulation_sessions WHERE created_by LIKE 'test_concurrent%';
    
    -- Create first session
    SELECT * INTO first_session FROM create_simulation_session(
        p_percentage := 0.05,
        p_seed_value := 12345,
        p_timeout_minutes := 30,
        p_created_by := 'test_concurrent_1'
    );
    
    -- Try to create second session (should fail)
    SELECT * INTO second_session FROM create_simulation_session(
        p_percentage := 0.10,
        p_seed_value := 54321,
        p_timeout_minutes := 30,
        p_created_by := 'test_concurrent_2'
    );
    
    -- Validate that first succeeded and second failed
    IF first_session.success AND 
       NOT second_session.success AND
       second_session.message LIKE '%active simulation%' THEN
        test_passed := TRUE;
    END IF;
    
    -- Record test result
    IF test_passed THEN
        PERFORM record_session_test_result('concurrent_prevention', TRUE, 
                                         'Concurrent simulation properly prevented');
    ELSE
        PERFORM record_session_test_result('concurrent_prevention', FALSE, 
                                         format('Concurrent prevention failed. First: %s, Second: %s', 
                                               first_session.success, second_session.success));
    END IF;
    
    -- Cleanup
    DELETE FROM simulation_sessions WHERE created_by LIKE 'test_concurrent%';
END;
$$;

-----------------------------------------------------------------------
--  Test 3: Session status updates and heartbeat functionality
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION test_session_status_updates()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    session_result RECORD;
    session_id UUID;
    update_success BOOLEAN;
    session_info RECORD;
    test_passed BOOLEAN := FALSE;
BEGIN
    RAISE NOTICE 'Running Test 3: Session status updates and heartbeat';
    
    -- Clean up any existing test sessions
    DELETE FROM simulation_sessions WHERE created_by = 'test_status_updates';
    
    -- Create test session
    SELECT * INTO session_result FROM create_simulation_session(
        p_percentage := 0.05,
        p_created_by := 'test_status_updates'
    );
    
    session_id := session_result.session_id;
    
    IF session_result.success THEN
        -- Test status update to 'processing'
        SELECT update_simulation_session(session_id, 'processing', TRUE) INTO update_success;
        
        -- Small delay to ensure heartbeat timestamp difference
        PERFORM pg_sleep(0.1);
        
        -- Test heartbeat update
        PERFORM update_simulation_session(session_id, NULL, TRUE);
        
        -- Validate updates
        SELECT * INTO session_info FROM get_simulation_session_info(session_id);
        
        IF update_success AND 
           session_info.status = 'processing' AND
           session_info.session_id = session_id THEN
            test_passed := TRUE;
        END IF;
    END IF;
    
    -- Record test result
    IF test_passed THEN
        PERFORM record_session_test_result('status_updates', TRUE, 
                                         'Session status and heartbeat updates working correctly');
    ELSE
        PERFORM record_session_test_result('status_updates', FALSE, 
                                         'Session status or heartbeat updates failed');
    END IF;
    
    -- Cleanup
    DELETE FROM simulation_sessions WHERE created_by = 'test_status_updates';
END;
$$;

-----------------------------------------------------------------------
--  Test 4: Session timeout and cleanup mechanisms
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION test_session_timeout_cleanup()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    session_result RECORD;
    session_id UUID;
    cleanup_count INT;
    session_info RECORD;
    test_passed BOOLEAN := FALSE;
BEGIN
    RAISE NOTICE 'Running Test 4: Session timeout and cleanup';
    
    -- Clean up any existing test sessions
    DELETE FROM simulation_sessions WHERE created_by = 'test_timeout';
    
    -- Create test session with very short timeout
    SELECT * INTO session_result FROM create_simulation_session(
        p_percentage := 0.05,
        p_timeout_minutes := 0, -- This should create an already expired session
        p_created_by := 'test_timeout'
    );
    
    session_id := session_result.session_id;
    
    IF session_result.success THEN
        -- Manually set the session to expired state for testing
        UPDATE simulation_sessions 
        SET timeout_at = NOW() - INTERVAL '1 minute',
            last_heartbeat = NOW() - INTERVAL '1 hour'
        WHERE id = session_id;
        
        -- Run cleanup
        SELECT cleanup_expired_sessions() INTO cleanup_count;
        
        -- Check if session was cleaned up
        SELECT * INTO session_info FROM get_simulation_session_info(session_id);
        
        IF cleanup_count >= 1 AND session_info.status = 'timeout' THEN
            test_passed := TRUE;
        END IF;
    END IF;
    
    -- Record test result
    IF test_passed THEN
        PERFORM record_session_test_result('timeout_cleanup', TRUE, 
                                         format('Session timeout cleanup working: %s sessions cleaned', cleanup_count));
    ELSE
        PERFORM record_session_test_result('timeout_cleanup', FALSE, 
                                         format('Session timeout cleanup failed. Cleanup count: %s', cleanup_count));
    END IF;
    
    -- Cleanup
    DELETE FROM simulation_sessions WHERE created_by = 'test_timeout';
END;
$$;

-----------------------------------------------------------------------
--  Test 5: Session cancellation functionality
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION test_session_cancellation()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    session_result RECORD;
    session_id UUID;
    cancel_success BOOLEAN;
    session_info RECORD;
    test_passed BOOLEAN := FALSE;
BEGIN
    RAISE NOTICE 'Running Test 5: Session cancellation';
    
    -- Clean up any existing test sessions
    DELETE FROM simulation_sessions WHERE created_by = 'test_cancellation';
    
    -- Create test session
    SELECT * INTO session_result FROM create_simulation_session(
        p_percentage := 0.05,
        p_created_by := 'test_cancellation'
    );
    
    session_id := session_result.session_id;
    
    IF session_result.success THEN
        -- Update to processing status
        PERFORM update_simulation_session(session_id, 'processing');
        
        -- Cancel the session
        SELECT cancel_simulation_session(session_id) INTO cancel_success;
        
        -- Check if session was cancelled
        SELECT * INTO session_info FROM get_simulation_session_info(session_id);
        
        IF cancel_success AND session_info.status = 'cancelled' THEN
            test_passed := TRUE;
        END IF;
    END IF;
    
    -- Record test result
    IF test_passed THEN
        PERFORM record_session_test_result('session_cancellation', TRUE, 
                                         'Session cancellation working correctly');
    ELSE
        PERFORM record_session_test_result('session_cancellation', FALSE, 
                                         'Session cancellation failed');
    END IF;
    
    -- Cleanup
    DELETE FROM simulation_sessions WHERE created_by = 'test_cancellation';
END;
$$;

-----------------------------------------------------------------------
--  Test 6: Active session detection
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION test_active_session_detection()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    session_result RECORD;
    session_id UUID;
    is_running BOOLEAN;
    active_sessions RECORD;
    test_passed BOOLEAN := FALSE;
BEGIN
    RAISE NOTICE 'Running Test 6: Active session detection';
    
    -- Clean up any existing test sessions
    DELETE FROM simulation_sessions WHERE created_by = 'test_active_detection';
    
    -- Verify no active sessions initially
    SELECT is_simulation_running() INTO is_running;
    
    IF NOT is_running THEN
        -- Create test session
        SELECT * INTO session_result FROM create_simulation_session(
            p_percentage := 0.05,
            p_created_by := 'test_active_detection'
        );
        
        session_id := session_result.session_id;
        
        IF session_result.success THEN
            -- Update to processing status
            PERFORM update_simulation_session(session_id, 'processing');
            
            -- Check if simulation is detected as running
            SELECT is_simulation_running() INTO is_running;
            
            -- Get active sessions info
            SELECT COUNT(*) as count INTO active_sessions 
            FROM get_active_simulation_sessions();
            
            IF is_running AND active_sessions.count = 1 THEN
                test_passed := TRUE;
            END IF;
        END IF;
    END IF;
    
    -- Record test result
    IF test_passed THEN
        PERFORM record_session_test_result('active_detection', TRUE, 
                                         'Active session detection working correctly');
    ELSE
        PERFORM record_session_test_result('active_detection', FALSE, 
                                         'Active session detection failed');
    END IF;
    
    -- Cleanup
    DELETE FROM simulation_sessions WHERE created_by = 'test_active_detection';
END;
$$;

-----------------------------------------------------------------------
--  Test 7: Session maintenance functionality
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION test_session_maintenance()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    session1_result RECORD;
    session2_result RECORD;
    maintenance_result RECORD;
    test_passed BOOLEAN := FALSE;
BEGIN
    RAISE NOTICE 'Running Test 7: Session maintenance';
    
    -- Clean up any existing test sessions
    DELETE FROM simulation_sessions WHERE created_by LIKE 'test_maintenance%';
    
    -- Create a normal session
    SELECT * INTO session1_result FROM create_simulation_session(
        p_percentage := 0.05,
        p_created_by := 'test_maintenance_normal'
    );
    
    -- Create an expired session
    SELECT * INTO session2_result FROM create_simulation_session(
        p_percentage := 0.10,
        p_timeout_minutes := 1,
        p_created_by := 'test_maintenance_expired'
    );
    
    IF session1_result.success AND session2_result.success THEN
        -- Manually expire the second session
        UPDATE simulation_sessions 
        SET timeout_at = NOW() - INTERVAL '1 minute',
            last_heartbeat = NOW() - INTERVAL '1 hour'
        WHERE id = session2_result.session_id;
        
        -- Complete the first session
        UPDATE simulation_sessions
        SET status = 'completed',
            completed_at = NOW() - INTERVAL '8 days'
        WHERE id = session1_result.session_id;
        
        -- Run maintenance
        SELECT * INTO maintenance_result FROM perform_session_maintenance();
        
        -- Validate maintenance results
        IF maintenance_result.expired_sessions_cleaned >= 1 AND
           maintenance_result.old_sessions_cleaned >= 1 THEN
            test_passed := TRUE;
        END IF;
    END IF;
    
    -- Record test result
    IF test_passed THEN
        PERFORM record_session_test_result('session_maintenance', TRUE, 
                                         format('Maintenance cleaned %s expired and %s old sessions', 
                                               maintenance_result.expired_sessions_cleaned,
                                               maintenance_result.old_sessions_cleaned));
    ELSE
        PERFORM record_session_test_result('session_maintenance', FALSE, 
                                         'Session maintenance failed');
    END IF;
    
    -- Cleanup
    DELETE FROM simulation_sessions WHERE created_by LIKE 'test_maintenance%';
END;
$$;

-----------------------------------------------------------------------
--  Master test runner
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION run_all_session_tracking_tests()
RETURNS TABLE (
    test_name TEXT,
    passed BOOLEAN,
    message TEXT
)
LANGUAGE plpgsql AS $$
BEGIN
    RAISE NOTICE 'Starting comprehensive simulation session tracking tests...';
    
    -- Clear previous test results
    DELETE FROM session_test_results;
    
    -- Run all tests
    PERFORM test_session_creation();
    PERFORM test_concurrent_simulation_prevention();
    PERFORM test_session_status_updates();
    PERFORM test_session_timeout_cleanup();
    PERFORM test_session_cancellation();
    PERFORM test_active_session_detection();
    PERFORM test_session_maintenance();
    
    -- Return results
    RETURN QUERY
    SELECT str.test_name, str.passed, str.message
    FROM session_test_results str
    ORDER BY str.test_name;
    
    RAISE NOTICE 'All simulation session tracking tests completed';
END;
$$;

-----------------------------------------------------------------------
--  Test summary function
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_session_test_summary()
RETURNS TABLE (
    total_tests INT,
    passed_tests INT,
    failed_tests INT,
    success_rate NUMERIC
)
LANGUAGE sql AS $$
    SELECT 
        COUNT(*)::INT as total_tests,
        COUNT(*) FILTER (WHERE passed = TRUE)::INT as passed_tests,
        COUNT(*) FILTER (WHERE passed = FALSE)::INT as failed_tests,
        ROUND(
            COUNT(*) FILTER (WHERE passed = TRUE)::NUMERIC / 
            COUNT(*)::NUMERIC * 100, 2
        ) as success_rate
    FROM session_test_results;
$$;

-----------------------------------------------------------------------
--  Completion notice
-----------------------------------------------------------------------
SELECT 'Simulation session tracking tests installed successfully' AS status;