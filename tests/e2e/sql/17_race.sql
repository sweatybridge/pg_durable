-- Test: Race execution with df.race() and | operator
-- Tests function and operator variants
-- Expected: First to complete wins

DROP TABLE IF EXISTS test_race_log;
CREATE TABLE test_race_log (id SERIAL, branch TEXT, variant TEXT, ts TIMESTAMP DEFAULT now());

-- Test A: df.race() function - fast vs slow
SELECT df.start(
    df.race(
        'INSERT INTO test_race_log (branch, variant) VALUES (''fast'', ''func'') RETURNING ''fast''',
        df.sleep(10) ~> 'INSERT INTO test_race_log (branch, variant) VALUES (''slow'', ''func'') RETURNING ''slow'''
    ),
    'test-race-func'
);

-- Test B: | operator - fast vs slow
SELECT df.start(
    'INSERT INTO test_race_log (branch, variant) VALUES (''fast'', ''op'') RETURNING ''fast'''
    | (df.sleep(10) ~> 'INSERT INTO test_race_log (branch, variant) VALUES (''slow'', ''op'') RETURNING ''slow'''),
    'test-race-op'
);

-- Wait for completion
SELECT pg_sleep(3);

-- Verify
DO $$
DECLARE
    status_func TEXT;
    status_op TEXT;
    cnt_func INT;
    cnt_op INT;
BEGIN
    SELECT status INTO status_func FROM df.instances WHERE label = 'test-race-func';
    SELECT status INTO status_op FROM df.instances WHERE label = 'test-race-op';
    
    IF lower(status_func) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [func]: status = %', status_func;
    END IF;
    
    IF lower(status_op) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [op]: status = %', status_op;
    END IF;
    
    -- Only the fast branch should have completed
    SELECT COUNT(*) INTO cnt_func FROM test_race_log WHERE variant = 'func' AND branch = 'fast';
    SELECT COUNT(*) INTO cnt_op FROM test_race_log WHERE variant = 'op' AND branch = 'fast';
    
    IF cnt_func < 1 THEN
        RAISE EXCEPTION 'TEST FAILED [func]: fast branch should have completed';
    END IF;
    
    IF cnt_op < 1 THEN
        RAISE EXCEPTION 'TEST FAILED [op]: fast branch should have completed';
    END IF;
    
    RAISE NOTICE 'PASSED: race [func + | operator]';
END $$;

DROP TABLE test_race_log;
SELECT 'TEST PASSED' AS result;

