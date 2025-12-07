-- Test: Sequential execution with ~>
-- Expected: Steps execute in order 1, 2, 3

DROP TABLE IF EXISTS test_sequence_log;
CREATE TABLE test_sequence_log (id SERIAL, step INT, ts TIMESTAMP DEFAULT now());

CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state SELECT durable.start(
    'INSERT INTO test_sequence_log (step) VALUES (1)'
    ~> 'INSERT INTO test_sequence_log (step) VALUES (2)'
    ~> 'INSERT INTO test_sequence_log (step) VALUES (3)',
    'test-sequence'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    steps INT[];
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
    
    SELECT array_agg(step ORDER BY id) INTO steps FROM test_sequence_log;
    IF steps != ARRAY[1,2,3] THEN
        RAISE EXCEPTION 'TEST FAILED: expected [1,2,3], got %', steps;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: sequence';
END $$;

DROP TABLE _test_state;
DROP TABLE test_sequence_log;
SELECT 'TEST PASSED' AS result;
