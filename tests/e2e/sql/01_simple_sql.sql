-- Test: Simple SQL execution
-- Expected: Completes successfully with result containing 42

CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state SELECT durable.start('SELECT 42 as answer', 'test-simple');

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    result TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    RAISE NOTICE 'Testing instance: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM durable.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: expected completed, got %', status;
    END IF;
    
    SELECT r INTO result FROM durable.result(inst_id) r;
    IF result NOT LIKE '%42%' THEN
        RAISE EXCEPTION 'TEST FAILED: result should contain 42, got %', result;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: simple_sql';
END $$;

DROP TABLE _test_state;
SELECT 'TEST PASSED' AS result;
