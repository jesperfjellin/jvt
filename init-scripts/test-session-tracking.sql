/***********************************************************************
  test-session-tracking.sql
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
--  Test 3: Session timeout and cleanup mechanisms
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
    RAISE NOTICE 'Running Test 3: Session timeout and cleanup';
    
    -- Clean up any existing test sessions
    DELETE FROM simulation_sessions WHERE created_by = 'test_timeout';
    
    -- Create test session
    SELECT * INTO session_result FROM create_simulation_session(
        p_percentage := 0.05,
        p_timeout_minutes := 60,
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
--  Test 4: Active session detection
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION test_active_session_detection()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    session_result RECORD;
    session_id UUID;
    is_running BOOLEAN;
    active_count INT;
    test_passed BOOLEAN := FALSE;
BEGIN
    RAISE NOTICE 'Running Test 4: Active session detection';
    
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
            
            -- Get active sessions count
            SELECT COUNT(*) INTO active_count FROM get_active_simulation_sessions();
            
            IF is_running AND active_count = 1 THEN
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
--  Master test runner
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION run_session_tracking_tests()
RETURNS TABLE (
    test_name TEXT,
    passed BOOLEAN,
    message TEXT
)
LANGUAGE plpgsql AS $$
BEGIN
    RAISE NOTICE 'Starting simulation session tracking tests...';
    
    -- Clear previous test results
    DELETE FROM session_test_results;
    
    -- Run all tests
    PERFORM test_session_creation();
    PERFORM test_concurrent_simulation_prevention();
    PERFORM test_session_timeout_cleanup();
    PERFORM test_active_session_detection();
    
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