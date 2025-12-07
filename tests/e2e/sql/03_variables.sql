-- Test: Variable substitution with |=> and $var
-- Expected: Second step receives value from first step

DROP TABLE IF EXISTS test_vars_log;
CREATE TABLE test_vars_log (id SERIAL, val TEXT);

CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state SELECT durable.start(
    'SELECT 100 as num' |=> 'x'
    ~> 'INSERT INTO test_vars_log (val) VALUES ($x::text)',
    'test-variables'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    val_result TEXT;
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
    
    SELECT val INTO val_result FROM test_vars_log ORDER BY id DESC LIMIT 1;
    IF val_result IS NULL OR val_result NOT LIKE '%100%' THEN
        RAISE EXCEPTION 'TEST FAILED: expected value containing 100, got %', val_result;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: variables';
END $$;

DROP TABLE _test_state;
DROP TABLE test_vars_log;
SELECT 'TEST PASSED' AS result;
