-- Test: Parallel execution with df.join() and & operator
-- Tests function and operator variants

DROP TABLE IF EXISTS test_parallel_log;
CREATE TABLE test_parallel_log (id SERIAL, branch TEXT, variant TEXT);

-- Test A: df.join() function
SELECT df.start(
    df.join(
        'INSERT INTO test_parallel_log (branch, variant) VALUES (''A'', ''func'')',
        'INSERT INTO test_parallel_log (branch, variant) VALUES (''B'', ''func'')'
    ),
    'test-parallel-func'
);

-- Test B: & operator
SELECT df.start(
    'INSERT INTO test_parallel_log (branch, variant) VALUES (''A'', ''op'')'
    & 'INSERT INTO test_parallel_log (branch, variant) VALUES (''B'', ''op'')',
    'test-parallel-op'
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
    SELECT status INTO status_func FROM df.instances WHERE label = 'test-parallel-func';
    SELECT status INTO status_op FROM df.instances WHERE label = 'test-parallel-op';
    
    IF lower(status_func) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [func]: status = %', status_func;
    END IF;
    
    IF lower(status_op) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [op]: status = %', status_op;
    END IF;
    
    SELECT COUNT(DISTINCT branch) INTO cnt_func FROM test_parallel_log WHERE variant = 'func';
    SELECT COUNT(DISTINCT branch) INTO cnt_op FROM test_parallel_log WHERE variant = 'op';
    
    IF cnt_func != 2 THEN
        RAISE EXCEPTION 'TEST FAILED [func]: expected 2 branches, got %', cnt_func;
    END IF;
    
    IF cnt_op != 2 THEN
        RAISE EXCEPTION 'TEST FAILED [op]: expected 2 branches, got %', cnt_op;
    END IF;
    
    RAISE NOTICE 'PASSED: parallel_join [func + & operator]';
END $$;

DROP TABLE test_parallel_log;
SELECT 'TEST PASSED' AS result;
