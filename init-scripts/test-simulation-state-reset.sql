/***********************************************************************
  test-simulation-state-reset.sql
  ----------------------------------------------------------------------
  Comprehensive tests for simulation state reset functionality.
  
  Tests cover:
  • Snapshot creation and restoration
  • State reset with various scenarios
  • Recovery from partial failures
  • Data integrity verification
***********************************************************************/

-----------------------------------------------------------------------
--  Test Setup: Create test schema and helper functions
-----------------------------------------------------------------------

-- Test results tracking
CREATE TEMP TABLE test_results (
    test_name TEXT PRIMARY KEY,
    status TEXT NOT NULL,
    message TEXT,
    executed_at TIMESTAMPTZ DEFAULT NOW()
);

-- Helper function to record test results
CREATE OR REPLACE FUNCTION record_test_result(
    test_name TEXT,
    success BOOLEAN,
    message TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql AS $
BEGIN
    INSERT INTO test_results (test_name, status, message)
    VALUES (test_name, CASE WHEN success THEN 'PASS' ELSE 'FAIL' END, message)
    ON CONFLICT (test_name) 
    DO UPDATE SET 
        status = EXCLUDED.status,
        message = EXCLUDED.message,
        executed_at = NOW();
END;
$;

-- Helper function to verify data counts
CREATE OR REPLACE FUNCTION verify_data_counts(
    expected_points INT,
    expected_lines INT,
    expected_polygons INT,
    test_context TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql AS $
DECLARE
    actual_points INT;
    actual_lines INT;
    actual_polygons INT;
BEGIN
    SELECT COUNT(*) INTO actual_points FROM demo_points;
    SELECT COUNT(*) INTO actual_lines FROM demo_lines;
    SELECT COUNT(*) INTO actual_polygons FROM demo_polygons;
    
    IF actual_points = expected_points AND 
       actual_lines = expected_lines AND 
       actual_polygons = expected_polygons THEN
        RAISE NOTICE '% - Data counts verified: % points, % lines, % polygons',
                     test_context, actual_points, actual_lines, actual_polygons;
        RETURN TRUE;
    ELSE
        RAISE WARNING '% - Data count mismatch. Expected: %/%/%, Actual: %/%/%',
                      test_context, expected_points, expected_lines, expected_polygons,
                      actual_points, actual_lines, actual_polygons;
        RETURN FALSE;
    END IF;
END;
$;

-----------------------------------------------------------------------
--  Test 1: Basic snapshot creation and restoration
-----------------------------------------------------------------------
DO $
DECLARE
    snapshot_id TEXT;
    restoration_success BOOLEAN;
    initial_points INT;
    initial_lines INT;
    initial_polygons INT;
BEGIN
    RAISE NOTICE 'Starting Test 1: Basic snapshot creation and restoration';
    
    -- Record initial state
    SELECT COUNT(*) INTO initial_points FROM demo_points;
    SELECT COUNT(*) INTO initial_lines FROM demo_lines;
    SELECT COUNT(*) INTO initial_polygons FROM demo_polygons;
    
    -- Create snapshot
    SELECT create_geometry_snapshot('test_snapshot_1') INTO snapshot_id;
    
    IF snapshot_id IS NOT NULL THEN
        -- Modify some data
        INSERT INTO demo_points (geom, demo_tag) 
        VALUES (ST_SetSRID(ST_MakePoint(0, 0), 3857), 'test_point_1');
        
        -- Verify modification
        IF (SELECT COUNT(*) FROM demo_points) = initial_points + 1 THEN
            -- Restore from snapshot
            SELECT restore_geometry_snapshot(snapshot_id) INTO restoration_success;
            
            IF restoration_success AND verify_data_counts(initial_points, initial_lines, initial_polygons, 'Test 1') THEN
                PERFORM record_test_result('basic_snapshot_creation_restoration', TRUE, 'Snapshot created and restored successfully');
            ELSE
                PERFORM record_test_result('basic_snapshot_creation_restoration', FALSE, 'Restoration failed or data counts incorrect');
            END IF;
        ELSE
            PERFORM record_test_result('basic_snapshot_creation_restoration', FALSE, 'Test data modification failed');
        END IF;
    ELSE
        PERFORM record_test_result('basic_snapshot_creation_restoration', FALSE, 'Snapshot creation failed');
    END IF;
    
    -- Cleanup
    DELETE FROM geometry_snapshots WHERE id = 'test_snapshot_1';
    DELETE FROM demo_points_backup WHERE snapshot_id = 'test_snapshot_1';
    DELETE FROM demo_lines_backup WHERE snapshot_id = 'test_snapshot_1';
    DELETE FROM demo_polygons_backup WHERE snapshot_id = 'test_snapshot_1';
END;
$;

-----------------------------------------------------------------------
--  Test 2: Reset simulation state with baseline snapshot
-----------------------------------------------------------------------
DO $
DECLARE
    reset_result RECORD;
    initial_points INT;
    initial_lines INT;
    initial_polygons INT;
    baseline_snapshot_id TEXT;
BEGIN
    RAISE NOTICE 'Starting Test 2: Reset simulation state with baseline snapshot';
    
    -- Record initial state
    SELECT COUNT(*) INTO initial_points FROM demo_points;
    SELECT COUNT(*) INTO initial_lines FROM demo_lines;
    SELECT COUNT(*) INTO initial_polygons FROM demo_polygons;
    
    -- Create baseline snapshot
    SELECT create_geometry_snapshot('test_baseline', TRUE) INTO baseline_snapshot_id;
    
    -- Simulate some changes (like a simulation would do)
    INSERT INTO demo_points (geom, demo_tag) 
    VALUES 
        (ST_SetSRID(ST_MakePoint(1000, 1000), 3857), 'sim_12345_point_1_1_1'),
        (ST_SetSRID(ST_MakePoint(2000, 2000), 3857), 'sim_12345_point_2_2_1');
    
    UPDATE demo_lines SET geom = ST_Translate(geom, 100, 100) WHERE id = 1;
    
    -- Add some changed tiles
    INSERT INTO changed_tiles (z, x, y, source_table, operation)
    VALUES (8, 1, 1, 'demo_points', 'INSERT'), (8, 2, 2, 'demo_lines', 'UPDATE');
    
    -- Reset simulation state
    SELECT * INTO reset_result FROM reset_simulation_state();
    
    IF reset_result.success AND 
       verify_data_counts(initial_points, initial_lines, initial_polygons, 'Test 2') AND
       (SELECT COUNT(*) FROM changed_tiles WHERE processed_at IS NULL) = 0 THEN
        PERFORM record_test_result('reset_simulation_state_baseline', TRUE, 
                                 format('Reset successful: %s', reset_result.message));
    ELSE
        PERFORM record_test_result('reset_simulation_state_baseline', FALSE, 
                                 format('Reset failed: %s', reset_result.message));
    END IF;
    
    -- Cleanup
    DELETE FROM geometry_snapshots WHERE id = 'test_baseline';
    DELETE FROM demo_points_backup WHERE snapshot_id = 'test_baseline';
    DELETE FROM demo_lines_backup WHERE snapshot_id = 'test_baseline';
    DELETE FROM demo_polygons_backup WHERE snapshot_id = 'test_baseline';
END;
$;

-----------------------------------------------------------------------
--  Test 3: Handle partial simulation failures
-----------------------------------------------------------------------
DO $
DECLARE
    snapshot_id TEXT;
    session_id UUID;
    reset_result RECORD;
    initial_points INT;
BEGIN
    RAISE NOTICE 'Starting Test 3: Handle partial simulation failures';
    
    SELECT COUNT(*) INTO initial_points FROM demo_points;
    
    -- Create baseline snapshot
    SELECT create_geometry_snapshot('test_failure_recovery', TRUE) INTO snapshot_id;
    
    -- Create a simulation session that appears to be stuck
    INSERT INTO simulation_sessions (percentage, status, started_at, snapshot_id)
    VALUES (0.05, 'processing', NOW() - INTERVAL '2 hours', snapshot_id)
    RETURNING id INTO session_id;
    
    -- Add some partial simulation data
    INSERT INTO demo_points (geom, demo_tag) 
    VALUES (ST_SetSRID(ST_MakePoint(3000, 3000), 3857), 'sim_partial_failure');
    
    -- Reset should handle the stuck session
    SELECT * INTO reset_result FROM reset_simulation_state();
    
    IF reset_result.success AND
       (SELECT status FROM simulation_sessions WHERE id = session_id) IN ('reset', 'failed') AND
       verify_data_counts(initial_points, (SELECT COUNT(*) FROM demo_lines), (SELECT COUNT(*) FROM demo_polygons), 'Test 3') THEN
        PERFORM record_test_result('handle_partial_simulation_failures', TRUE, 
                                 'Partial failure recovery successful');
    ELSE
        PERFORM record_test_result('handle_partial_simulation_failures', FALSE, 
                                 'Partial failure recovery failed');
    END IF;
    
    -- Cleanup
    DELETE FROM simulation_sessions WHERE id = session_id;
    DELETE FROM geometry_snapshots WHERE id = 'test_failure_recovery';
    DELETE FROM demo_points_backup WHERE snapshot_id = 'test_failure_recovery';
    DELETE FROM demo_lines_backup WHERE snapshot_id = 'test_failure_recovery';
    DELETE FROM demo_polygons_backup WHERE snapshot_id = 'test_failure_recovery';
END;
$;

-----------------------------------------------------------------------
--  Test 4: Recovery from incomplete simulations
-----------------------------------------------------------------------
DO $
DECLARE
    recovery_result RECORD;
    session_id UUID;
    initial_count INT;
BEGIN
    RAISE NOTICE 'Starting Test 4: Recovery from incomplete simulations';
    
    SELECT COUNT(*) INTO initial_count FROM demo_points;
    
    -- Create stuck simulation sessions
    INSERT INTO simulation_sessions (percentage, status, started_at)
    VALUES 
        (0.05, 'starting', NOW() - INTERVAL '2 hours'),
        (0.10, 'processing', NOW() - INTERVAL '3 hours')
    RETURNING id INTO session_id;
    
    -- Run recovery
    SELECT * INTO recovery_result FROM recover_from_incomplete_simulation();
    
    IF recovery_result.recovery_needed AND 
       recovery_result.sessions_cleaned >= 2 AND
       (SELECT COUNT(*) FROM simulation_sessions WHERE status IN ('starting', 'processing')) = 0 THEN
        PERFORM record_test_result('recovery_incomplete_simulations', TRUE, 
                                 format('Recovery successful: %s', recovery_result.recovery_action));
    ELSE
        PERFORM record_test_result('recovery_incomplete_simulations', FALSE, 
                                 format('Recovery failed or not needed: %s', recovery_result.recovery_action));
    END IF;
    
    -- Cleanup
    DELETE FROM simulation_sessions WHERE status = 'failed';
END;
$;

-----------------------------------------------------------------------
--  Test 5: Snapshot cleanup functionality
-----------------------------------------------------------------------
DO $
DECLARE
    snapshot_ids TEXT[];
    i INT;
    deleted_count INT;
    remaining_count INT;
BEGIN
    RAISE NOTICE 'Starting Test 5: Snapshot cleanup functionality';
    
    -- Create multiple test snapshots
    FOR i IN 1..7 LOOP
        snapshot_ids := array_append(snapshot_ids, create_geometry_snapshot('cleanup_test_' || i, i <= 2));
        PERFORM pg_sleep(0.01); -- Small delay to ensure different timestamps
    END LOOP;
    
    -- Run cleanup (keep 3, preserve baseline)
    SELECT cleanup_old_snapshots(3, TRUE) INTO deleted_count;
    
    -- Check remaining snapshots
    SELECT COUNT(*) INTO remaining_count 
    FROM geometry_snapshots 
    WHERE id LIKE 'cleanup_test_%';
    
    -- Should have kept 3 non-baseline + 2 baseline = 5 total
    IF deleted_count = 2 AND remaining_count = 5 THEN
        PERFORM record_test_result('snapshot_cleanup', TRUE, 
                                 format('Cleanup successful: %s deleted, %s remaining', deleted_count, remaining_count));
    ELSE
        PERFORM record_test_result('snapshot_cleanup', FALSE, 
                                 format('Cleanup failed: %s deleted, %s remaining (expected 2 deleted, 5 remaining)', 
                                        deleted_count, remaining_count));
    END IF;
    
    -- Cleanup test snapshots
    DELETE FROM geometry_snapshots WHERE id LIKE 'cleanup_test_%';
    DELETE FROM demo_points_backup WHERE snapshot_id LIKE 'cleanup_test_%';
    DELETE FROM demo_lines_backup WHERE snapshot_id LIKE 'cleanup_test_%';
    DELETE FROM demo_polygons_backup WHERE snapshot_id LIKE 'cleanup_test_%';
END;
$;

-----------------------------------------------------------------------
--  Test 6: Simulation state info function
-----------------------------------------------------------------------
DO $
DECLARE
    state_info RECORD;
    session_id UUID;
    snapshot_id TEXT;
BEGIN
    RAISE NOTICE 'Starting Test 6: Simulation state info function';
    
    -- Create test data
    INSERT INTO simulation_sessions (percentage, status)
    VALUES (0.05, 'processing')
    RETURNING id INTO session_id;
    
    SELECT create_geometry_snapshot('info_test', TRUE) INTO snapshot_id;
    
    -- Get state info
    SELECT * INTO state_info FROM get_simulation_state_info();
    
    IF state_info.active_sessions >= 1 AND 
       state_info.available_snapshots >= 1 AND
       state_info.baseline_snapshots >= 1 AND
       state_info.current_points > 0 THEN
        PERFORM record_test_result('simulation_state_info', TRUE, 
                                 format('State info correct: %s active, %s snapshots, %s baseline', 
                                        state_info.active_sessions, state_info.available_snapshots, 
                                        state_info.baseline_snapshots));
    ELSE
        PERFORM record_test_result('simulation_state_info', FALSE, 
                                 'State info function returned unexpected values');
    END IF;
    
    -- Cleanup
    DELETE FROM simulation_sessions WHERE id = session_id;
    DELETE FROM geometry_snapshots WHERE id = 'info_test';
    DELETE FROM demo_points_backup WHERE snapshot_id = 'info_test';
    DELETE FROM demo_lines_backup WHERE snapshot_id = 'info_test';
    DELETE FROM demo_polygons_backup WHERE snapshot_id = 'info_test';
END;
$;

-----------------------------------------------------------------------
--  Test 7: Data integrity after multiple operations
-----------------------------------------------------------------------
DO $
DECLARE
    original_points INT;
    original_lines INT;
    original_polygons INT;
    snapshot_id TEXT;
    reset_result RECORD;
    final_points INT;
    final_lines INT;
    final_polygons INT;
BEGIN
    RAISE NOTICE 'Starting Test 7: Data integrity after multiple operations';
    
    -- Record original state
    SELECT COUNT(*) INTO original_points FROM demo_points;
    SELECT COUNT(*) INTO original_lines FROM demo_lines;
    SELECT COUNT(*) INTO original_polygons FROM demo_polygons;
    
    -- Create baseline
    SELECT create_geometry_snapshot('integrity_test', TRUE) INTO snapshot_id;
    
    -- Perform multiple modifications
    INSERT INTO demo_points (geom, demo_tag) 
    SELECT ST_SetSRID(ST_MakePoint(i * 1000, i * 1000), 3857), 'integrity_test_' || i
    FROM generate_series(1, 10) i;
    
    DELETE FROM demo_points WHERE id IN (SELECT id FROM demo_points LIMIT 5);
    
    UPDATE demo_lines SET geom = ST_Translate(geom, 500, 500);
    
    -- Reset state
    SELECT * INTO reset_result FROM reset_simulation_state();
    
    -- Verify final state matches original
    SELECT COUNT(*) INTO final_points FROM demo_points;
    SELECT COUNT(*) INTO final_lines FROM demo_lines;
    SELECT COUNT(*) INTO final_polygons FROM demo_polygons;
    
    IF reset_result.success AND 
       final_points = original_points AND 
       final_lines = original_lines AND 
       final_polygons = original_polygons THEN
        PERFORM record_test_result('data_integrity_multiple_operations', TRUE, 
                                 'Data integrity maintained after multiple operations');
    ELSE
        PERFORM record_test_result('data_integrity_multiple_operations', FALSE, 
                                 format('Data integrity failed: %s/%s/%s vs %s/%s/%s', 
                                        final_points, final_lines, final_polygons,
                                        original_points, original_lines, original_polygons));
    END IF;
    
    -- Cleanup
    DELETE FROM geometry_snapshots WHERE id = 'integrity_test';
    DELETE FROM demo_points_backup WHERE snapshot_id = 'integrity_test';
    DELETE FROM demo_lines_backup WHERE snapshot_id = 'integrity_test';
    DELETE FROM demo_polygons_backup WHERE snapshot_id = 'integrity_test';
END;
$;

-----------------------------------------------------------------------
--  Test Results Summary
-----------------------------------------------------------------------
SELECT 
    'SIMULATION STATE RESET TEST RESULTS' AS summary,
    COUNT(*) AS total_tests,
    COUNT(*) FILTER (WHERE status = 'PASS') AS passed,
    COUNT(*) FILTER (WHERE status = 'FAIL') AS failed,
    ROUND(COUNT(*) FILTER (WHERE status = 'PASS') * 100.0 / COUNT(*), 1) AS pass_rate
FROM test_results;

-- Detailed results
SELECT 
    test_name,
    status,
    message,
    executed_at
FROM test_results
ORDER BY executed_at;

-- Show any failures in detail
SELECT 
    'FAILED TESTS DETAIL' AS section,
    test_name,
    message
FROM test_results
WHERE status = 'FAIL';

-----------------------------------------------------------------------
--  Cleanup test functions
-----------------------------------------------------------------------
DROP FUNCTION IF EXISTS record_test_result(TEXT, BOOLEAN, TEXT);
DROP FUNCTION IF EXISTS verify_data_counts(INT, INT, INT, TEXT);

SELECT 'Simulation state reset tests completed' AS status;