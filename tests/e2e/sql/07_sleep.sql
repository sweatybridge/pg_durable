-- Test: Sleep/timer functionality
-- Expected: Function completes after sleeping

DROP TABLE IF EXISTS test_sleep_log;
CREATE TABLE test_sleep_log (id SERIAL, ts TIMESTAMP DEFAULT now());

INSERT INTO test_sleep_log DEFAULT VALUES;

CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state SELECT durable.start(
    durable.sleep(2) ~> 'INSERT INTO test_sleep_log DEFAULT VALUES',
    'test-sleep'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    cnt INT;
    time_diff INTERVAL;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    RAISE NOTICE 'Testing instance: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM durable.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 500;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: status = %', status;
    END IF;
    
    SELECT COUNT(*) INTO cnt FROM test_sleep_log;
    IF cnt != 2 THEN
        RAISE EXCEPTION 'TEST FAILED: expected 2 log entries, got %', cnt;
    END IF;
    
    SELECT MAX(ts) - MIN(ts) INTO time_diff FROM test_sleep_log;
    IF time_diff < interval '1.5 seconds' THEN
        RAISE EXCEPTION 'TEST FAILED: sleep should be at least 2s, got %', time_diff;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: sleep';
END $$;

DROP TABLE _test_state;
DROP TABLE test_sleep_log;
SELECT 'TEST PASSED' AS result;
