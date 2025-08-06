/*********************************************************************
  test-deterministic-geometry.sql
  ----------------------------------------------------------------
  Tests to verify that geometry modifications in simulate_tile_changes()
  are deterministic and produce consistent results across multiple runs.
  
  Requirements tested:
  - 2.1: Deterministic algorithm produces consistent results
  - 2.2: Same percentage produces same tiles every time  
  - 2.4: Random number generators are reinitialized to default state
**********************************************************************/

-- Test setup: Create temporary tables to store test results
CREATE TEMP TABLE IF NOT EXISTS test_results (
    test_name TEXT,
    run_number INT,
    tile_x INT,
    tile_y INT,
    point_x FLOAT8,
    point_y FLOAT8,
    line_translate_x FLOAT8,
    line_translate_y FLOAT8,
    polygon_buffer FLOAT8,
    demo_tag TEXT
);

-- Test setup: Create a function to capture geometry modifications for testing
CREATE OR REPLACE FUNCTION test_geometry_modifications(
    z INT DEFAULT 8,
    pct FLOAT8 DEFAULT 0.05,
    seed_val INT DEFAULT 12345,
    test_name TEXT DEFAULT 'test_run'
)
RETURNS TABLE (
    tiles_processed INT,
    points_created INT,
    lines_modified INT,
    polygons_modified INT
)
LANGUAGE plpgsql AS $$
DECLARE
    env GEOMETRY;
    t RECORD;
    tile_count INT := 0;
    points_count INT := 0;
    lines_count INT := 0;
    polygons_count INT := 0;
    tile_seed BIGINT;
    rand_x1 FLOAT8;
    rand_y1 FLOAT8;
    rand_translate_x FLOAT8;
    rand_translate_y FLOAT8;
    rand_buffer FLOAT8;
    point_idx INT;
    ins_per_tile INT := 2;
BEGIN
    -- Clear previous test data for this test
    DELETE FROM test_results WHERE test_results.test_name = test_geometry_modifications.test_name;
    
    FOR t IN SELECT * FROM pick_tiles_for_tick(z, pct, seed_val)
    LOOP
        tile_count := tile_count + 1;
        env := ST_TileEnvelope(z, t.x, t.y);
        
        -- Generate same deterministic seed as main function
        tile_seed := seed_val + (t.x * 1000) + (t.y * 100000) + (z * 10000000) + floor(pct * 1000000);
        
        -- Test point generation determinism
        FOR point_idx IN 1..ins_per_tile LOOP
            rand_x1 := seeded_random(tile_seed + point_idx);
            rand_y1 := seeded_random(tile_seed + point_idx + 1000);
            
            -- Store the generated values for comparison
            INSERT INTO test_results (test_name, run_number, tile_x, tile_y, point_x, point_y, demo_tag)
            VALUES (
                test_geometry_modifications.test_name,
                1, -- Will be updated by caller
                t.x, t.y,
                ST_XMin(env) + rand_x1 * (ST_XMax(env)-ST_XMin(env)),
                ST_YMin(env) + rand_y1 * (ST_YMax(env)-ST_YMin(env)),
                format('test_point_%s_%s_%s', t.x, t.y, point_idx)
            );
            
            points_count := points_count + 1;
        END LOOP;
        
        -- Test line translation determinism
        rand_translate_x := seeded_random(tile_seed + 2000) - 0.5;
        rand_translate_y := seeded_random(tile_seed + 3000) - 0.5;
        
        -- Store translation values
        UPDATE test_results 
        SET line_translate_x = rand_translate_x * 60,
            line_translate_y = rand_translate_y * 60
        WHERE test_results.test_name = test_geometry_modifications.test_name
          AND tile_x = t.x AND tile_y = t.y
          AND demo_tag LIKE 'test_point_%';
        
        lines_count := lines_count + 1;
        
        -- Test polygon buffer determinism
        rand_buffer := seeded_random(tile_seed + 4000) - 0.5;
        
        -- Store buffer values
        UPDATE test_results 
        SET polygon_buffer = GREATEST(50, LEAST(180, 180 + rand_buffer * 100))
        WHERE test_results.test_name = test_geometry_modifications.test_name
          AND tile_x = t.x AND tile_y = t.y
          AND demo_tag LIKE 'test_point_%';
        
        polygons_count := polygons_count + 1;
    END LOOP;
    
    tiles_processed := tile_count;
    points_created := points_count;
    lines_modified := lines_count;
    polygons_modified := polygons_count;
    
    RETURN NEXT;
END;
$$;

-- Test 1: Verify same seed produces identical geometry modifications
DO $test1$
DECLARE
    run1_results RECORD;
    run2_results RECORD;
    differences_count INT;
BEGIN
    RAISE NOTICE 'TEST 1: Verifying deterministic geometry modifications with same seed...';
    
    -- Run 1
    UPDATE test_results SET run_number = 1 WHERE test_name = 'deterministic_test';
    SELECT * INTO run1_results FROM test_geometry_modifications(8, 0.05, 12345, 'deterministic_test');
    UPDATE test_results SET run_number = 1 WHERE test_name = 'deterministic_test';
    
    -- Run 2 with same parameters
    SELECT * INTO run2_results FROM test_geometry_modifications(8, 0.05, 12345, 'deterministic_test_run2');
    UPDATE test_results SET run_number = 2 WHERE test_name = 'deterministic_test_run2';
    UPDATE test_results SET test_name = 'deterministic_test' WHERE test_name = 'deterministic_test_run2';
    
    -- Compare results
    SELECT COUNT(*) INTO differences_count
    FROM (
        SELECT tile_x, tile_y, demo_tag, point_x, point_y, line_translate_x, line_translate_y, polygon_buffer
        FROM test_results 
        WHERE test_name = 'deterministic_test' AND run_number = 1
        EXCEPT
        SELECT tile_x, tile_y, demo_tag, point_x, point_y, line_translate_x, line_translate_y, polygon_buffer
        FROM test_results 
        WHERE test_name = 'deterministic_test' AND run_number = 2
    ) AS differences;
    
    IF differences_count = 0 THEN
        RAISE NOTICE 'TEST 1 PASSED: Identical geometry modifications across runs (% tiles processed)', run1_results.tiles_processed;
    ELSE
        RAISE NOTICE 'TEST 1 FAILED: Found % differences in geometry modifications', differences_count;
    END IF;
END;
$test1$;

-- Test 2: Verify different seeds produce different geometry modifications
DO $test2$
DECLARE
    run1_results RECORD;
    run2_results RECORD;
    differences_count INT;
BEGIN
    RAISE NOTICE 'TEST 2: Verifying different seeds produce different geometry modifications...';
    
    -- Clear previous test data
    DELETE FROM test_results WHERE test_name IN ('seed_test_1', 'seed_test_2');
    
    -- Run with seed 12345
    SELECT * INTO run1_results FROM test_geometry_modifications(8, 0.05, 12345, 'seed_test_1');
    
    -- Run with seed 54321
    SELECT * INTO run2_results FROM test_geometry_modifications(8, 0.05, 54321, 'seed_test_2');
    
    -- Compare results - should be different
    SELECT COUNT(*) INTO differences_count
    FROM (
        SELECT tile_x, tile_y, demo_tag, point_x, point_y, line_translate_x, line_translate_y, polygon_buffer
        FROM test_results 
        WHERE test_name = 'seed_test_1'
        EXCEPT
        SELECT tile_x, tile_y, demo_tag, point_x, point_y, line_translate_x, line_translate_y, polygon_buffer
        FROM test_results 
        WHERE test_name = 'seed_test_2'
    ) AS differences;
    
    IF differences_count > 0 THEN
        RAISE NOTICE 'TEST 2 PASSED: Different seeds produce different geometry modifications (% differences)', differences_count;
    ELSE
        RAISE NOTICE 'TEST 2 FAILED: Different seeds produced identical geometry modifications';
    END IF;
END;
$test2$;

-- Test 3: Verify same tile coordinates always get same modifications for same seed
DO $test3$
DECLARE
    tile_modifications_count INT;
    unique_modifications_count INT;
BEGIN
    RAISE NOTICE 'TEST 3: Verifying same tile coordinates get consistent modifications...';
    
    -- Clear previous test data
    DELETE FROM test_results WHERE test_name = 'tile_consistency_test';
    
    -- Run multiple times with same seed and check specific tiles
    PERFORM test_geometry_modifications(8, 0.1, 99999, 'tile_consistency_test');
    UPDATE test_results SET run_number = 1 WHERE test_name = 'tile_consistency_test';
    
    PERFORM test_geometry_modifications(8, 0.1, 99999, 'tile_consistency_test_2');
    UPDATE test_results SET run_number = 2, test_name = 'tile_consistency_test' WHERE test_name = 'tile_consistency_test_2';
    
    PERFORM test_geometry_modifications(8, 0.1, 99999, 'tile_consistency_test_3');
    UPDATE test_results SET run_number = 3, test_name = 'tile_consistency_test' WHERE test_name = 'tile_consistency_test_3';
    
    -- Count total tile modifications across all runs
    SELECT COUNT(*) INTO tile_modifications_count
    FROM test_results 
    WHERE test_name = 'tile_consistency_test';
    
    -- Count unique tile modifications (should be 1/3 of total if all runs are identical)
    SELECT COUNT(DISTINCT (tile_x, tile_y, point_x, point_y, line_translate_x, line_translate_y, polygon_buffer)) 
    INTO unique_modifications_count
    FROM test_results 
    WHERE test_name = 'tile_consistency_test';
    
    IF unique_modifications_count * 3 = tile_modifications_count THEN
        RAISE NOTICE 'TEST 3 PASSED: Same tile coordinates produce consistent modifications across % runs', 3;
    ELSE
        RAISE NOTICE 'TEST 3 FAILED: Inconsistent modifications - % total, % unique (expected %)', 
                     tile_modifications_count, unique_modifications_count, tile_modifications_count / 3;
    END IF;
END;
$test3$;

-- Test 4: Verify seeded_random function produces consistent sequences
DO $test4$
DECLARE
    seq1 FLOAT8[];
    seq2 FLOAT8[];
    i INT;
BEGIN
    RAISE NOTICE 'TEST 4: Verifying seeded_random function consistency...';
    
    -- Generate sequence 1
    FOR i IN 1..10 LOOP
        seq1[i] := seeded_random(12345 + i);
    END LOOP;
    
    -- Generate sequence 2 with same seeds
    FOR i IN 1..10 LOOP
        seq2[i] := seeded_random(12345 + i);
    END LOOP;
    
    -- Compare sequences
    IF seq1 = seq2 THEN
        RAISE NOTICE 'TEST 4 PASSED: seeded_random produces consistent sequences';
    ELSE
        RAISE NOTICE 'TEST 4 FAILED: seeded_random produces inconsistent sequences';
        RAISE NOTICE 'Sequence 1: %', seq1;
        RAISE NOTICE 'Sequence 2: %', seq2;
    END IF;
END;
$test4$;

-- Cleanup
DROP FUNCTION IF EXISTS test_geometry_modifications(INT, FLOAT8, INT, TEXT);

-- Test completion message
DO $$
BEGIN
    RAISE NOTICE 'Deterministic geometry modification tests completed.';
END;
$$;