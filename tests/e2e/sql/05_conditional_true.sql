-- Test: Conditional execution - true branch
-- Tests both auto-wrapped SQL and explicit durable.sql() variants
-- Expected: Then branch executes when condition is true

DROP TABLE IF EXISTS test_cond_log;
CREATE TABLE test_cond_log (id SERIAL, branch TEXT, variant TEXT);

CREATE TEMP TABLE _test_state (instance_id TEXT, variant TEXT);

-- Variant A: Auto-wrapped SQL strings
INSERT INTO _test_state SELECT durable.start(
    durable.if(
        'SELECT true',
        'INSERT INTO test_cond_log (branch, variant) VALUES (''then'', ''auto'')',
        'INSERT INTO test_cond_log (branch, variant) VALUES (''else'', ''auto'')'
    ),
    'test-cond-true-auto'
), 'auto';

-- Variant B: Explicit durable.sql() wrapping
INSERT INTO _test_state SELECT durable.start(
    durable.if(
        durable.sql('SELECT true'),
        durable.sql('INSERT INTO test_cond_log (branch, variant) VALUES (''then'', ''func'')'),
        durable.sql('INSERT INTO test_cond_log (branch, variant) VALUES (''else'', ''func'')')
    ),
    'test-cond-true-func'
), 'func';

DO $$
DECLARE
    rec RECORD;
    status TEXT;
    branch_val TEXT;
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
            RAISE EXCEPTION 'TEST FAILED [%]: status = %', rec.variant, status;
        END IF;
        
        SELECT branch INTO branch_val 
        FROM test_cond_log WHERE variant = rec.variant ORDER BY id DESC LIMIT 1;
        
        IF branch_val != 'then' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: expected then branch, got %', rec.variant, branch_val;
        END IF;
        
        RAISE NOTICE 'PASSED: conditional_true [%]', rec.variant;
    END LOOP;
    
    RAISE NOTICE 'TEST PASSED: conditional_true (both variants)';
END $$;

DROP TABLE _test_state;
DROP TABLE test_cond_log;
SELECT 'TEST PASSED' AS result;
