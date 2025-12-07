-- Test: Simple SQL execution
-- Tests both auto-wrapped SQL and explicit durable.sql() function
-- Expected: Both complete successfully with result containing 42

CREATE TEMP TABLE _test_state (instance_id TEXT, variant TEXT);

-- Variant A: Auto-wrapped SQL (plain string)
INSERT INTO _test_state 
SELECT durable.start('SELECT 42 as answer', 'test-simple-auto'), 'auto';

-- Variant B: Explicit durable.sql() function
INSERT INTO _test_state 
SELECT durable.start(durable.sql('SELECT 42 as answer'), 'test-simple-func'), 'func';

DO $$
DECLARE
    rec RECORD;
    status TEXT;
    result TEXT;
    attempts INT;
BEGIN
    FOR rec IN SELECT instance_id, variant FROM _test_state LOOP
        RAISE NOTICE 'Testing % variant: %', rec.variant, rec.instance_id;
        attempts := 0;
        
        LOOP
            SELECT s INTO status FROM durable.status(rec.instance_id) s;
            EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
            PERFORM pg_sleep(0.1);
            attempts := attempts + 1;
        END LOOP;
        
        IF lower(status) != 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: expected completed, got %', rec.variant, status;
        END IF;
        
        SELECT r INTO result FROM durable.result(rec.instance_id) r;
        IF result NOT LIKE '%42%' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: result should contain 42, got %', rec.variant, result;
        END IF;
        
        RAISE NOTICE 'PASSED: simple_sql [%]', rec.variant;
    END LOOP;
    
    RAISE NOTICE 'TEST PASSED: simple_sql (both variants)';
END $$;

DROP TABLE _test_state;
SELECT 'TEST PASSED' AS result;
