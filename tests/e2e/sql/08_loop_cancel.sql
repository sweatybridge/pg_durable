-- Test: Loop execution and cancellation
-- Expected: Loop runs multiple iterations, then stops on cancel

DROP TABLE IF EXISTS test_loop_log;
CREATE TABLE test_loop_log (id SERIAL, iteration INT, ts TIMESTAMP DEFAULT now());

CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state SELECT durable.start(
    durable.loop(
        'INSERT INTO test_loop_log (iteration) VALUES ((SELECT COALESCE(MAX(iteration), 0) + 1 FROM test_loop_log))'
        ~> durable.sleep(1)
    ),
    'test-loop'
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
    
    -- Wait for at least 2 iterations
    LOOP
        SELECT COUNT(*) INTO cnt FROM test_loop_log;
        EXIT WHEN cnt >= 2 OR attempts > 100;
        PERFORM pg_sleep(0.5);
        attempts := attempts + 1;
    END LOOP;
    
    IF cnt < 2 THEN
        RAISE EXCEPTION 'TEST FAILED: expected at least 2 iterations, got %', cnt;
    END IF;
    
    -- Cancel the loop
    PERFORM durable.cancel(inst_id, 'Test complete');
    
    -- Wait for cancellation
    attempts := 0;
    LOOP
        SELECT s INTO status FROM durable.status(inst_id) s;
        EXIT WHEN lower(status) IN ('canceled', 'cancelled', 'failed') OR attempts > 100;
        PERFORM pg_sleep(0.2);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) NOT IN ('canceled', 'cancelled') THEN
        RAISE EXCEPTION 'TEST FAILED: expected Canceled, got %', status;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: loop_cancel';
END $$;

DROP TABLE _test_state;
DROP TABLE test_loop_log;
SELECT 'TEST PASSED' AS result;
