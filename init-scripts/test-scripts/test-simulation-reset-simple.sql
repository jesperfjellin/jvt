-- Simple test for simulation state reset functionality
-- This demonstrates the key functions working correctly

-- Test 1: Create a snapshot
SELECT 'Test 1: Creating snapshot' AS test;
SELECT create_geometry_snapshot('demo_test', TRUE) AS snapshot_created;

-- Test 2: Check current data count
SELECT 'Test 2: Current data count' AS test;
SELECT COUNT(*) AS current_points FROM demo_points;

-- Test 3: Add some simulation data
SELECT 'Test 3: Adding simulation data' AS test;
INSERT INTO demo_points (geom, demo_tag) 
VALUES 
    (ST_SetSRID(ST_MakePoint(1000, 1000), 3857), 'sim_12345_test_1'),
    (ST_SetSRID(ST_MakePoint(2000, 2000), 3857), 'sim_12345_test_2');

SELECT COUNT(*) AS points_after_simulation FROM demo_points;
SELECT COUNT(*) AS simulation_points FROM demo_points WHERE demo_tag LIKE 'sim_%';

-- Test 4: Reset simulation state
SELECT 'Test 4: Resetting simulation state' AS test;
SELECT success, message, points_restored, tiles_cleared 
FROM reset_simulation_state();

-- Test 5: Verify reset worked
SELECT 'Test 5: Verifying reset' AS test;
SELECT COUNT(*) AS final_points FROM demo_points;
SELECT COUNT(*) AS remaining_sim_points FROM demo_points WHERE demo_tag LIKE 'sim_%';

-- Test 6: Check simulation state info
SELECT 'Test 6: Simulation state info' AS test;
SELECT active_sessions, available_snapshots, baseline_snapshots, simulation_generated_points
FROM get_simulation_state_info();

-- Cleanup
DELETE FROM geometry_snapshots WHERE id = 'demo_test';
DELETE FROM demo_points_backup WHERE snapshot_id = 'demo_test';

SELECT 'All tests completed successfully!' AS result;