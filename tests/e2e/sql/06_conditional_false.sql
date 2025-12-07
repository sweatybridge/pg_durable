-- Test: Conditional execution - false branch
-- Expected: Else branch executes when condition is false

DROP TABLE IF EXISTS test_cond_false_log;
CREATE TABLE test_cond_false_log (id SERIAL, branch TEXT);

CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state SELECT durable.start(
    durable.if(
        'SELECT false',
        'INSERT INTO test_cond_false_log (branch) VALUES (''then'')',
        'INSERT INTO test_cond_false_log (branch) VALUES (''else'')'
    ),
    'test-cond-false'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    branch_val TEXT;
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
        RAISE EXCEPTION 'TEST FAILED: status = %', status;
    END IF;
    
    SELECT branch INTO branch_val FROM test_cond_false_log ORDER BY id DESC LIMIT 1;
    IF branch_val != 'else' THEN
        RAISE EXCEPTION 'TEST FAILED: expected else branch, got %', branch_val;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: conditional_false';
END $$;

DROP TABLE _test_state;
DROP TABLE test_cond_false_log;
SELECT 'TEST PASSED' AS result;
