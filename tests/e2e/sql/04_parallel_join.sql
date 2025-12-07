-- Test: Parallel execution with durable.join()
-- Expected: Both branches execute

DROP TABLE IF EXISTS test_parallel_log;
CREATE TABLE test_parallel_log (id SERIAL, branch TEXT, ts TIMESTAMP DEFAULT now());

CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state SELECT durable.start(
    durable.join(
        'INSERT INTO test_parallel_log (branch) VALUES (''A'')',
        'INSERT INTO test_parallel_log (branch) VALUES (''B'')'
    ),
    'test-parallel'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    cnt INT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    RAISE NOTICE 'Testing instance: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM durable.status(inst_id) s;
        -- Debug: show status every 50 attempts
        IF attempts % 50 = 0 THEN
            RAISE NOTICE 'Status after % attempts: %', attempts, status;
        END IF;
        EXIT WHEN status IN ('Completed', 'completed', 'Failed', 'failed', 'Canceled', 'canceled', 'ContinuedAsNew') OR attempts > 600;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: status = %', status;
    END IF;
    
    SELECT COUNT(DISTINCT branch) INTO cnt FROM test_parallel_log;
    IF cnt != 2 THEN
        RAISE EXCEPTION 'TEST FAILED: expected 2 branches, got %', cnt;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: parallel_join';
END $$;

DROP TABLE _test_state;
DROP TABLE test_parallel_log;
SELECT 'TEST PASSED' AS result;
