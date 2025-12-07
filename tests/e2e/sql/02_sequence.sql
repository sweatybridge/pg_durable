-- Test: Sequential execution
-- Tests both ~> operator and durable.seq() function
-- Expected: Steps execute in order 1, 2, 3

DROP TABLE IF EXISTS test_sequence_log;
CREATE TABLE test_sequence_log (id SERIAL, step INT, variant TEXT, ts TIMESTAMP DEFAULT now());

CREATE TEMP TABLE _test_state (instance_id TEXT, variant TEXT);

-- Variant A: Using ~> operator
INSERT INTO _test_state SELECT durable.start(
    'INSERT INTO test_sequence_log (step, variant) VALUES (1, ''op'')'
    ~> 'INSERT INTO test_sequence_log (step, variant) VALUES (2, ''op'')'
    ~> 'INSERT INTO test_sequence_log (step, variant) VALUES (3, ''op'')',
    'test-sequence-op'
), 'operator';

-- Variant B: Using durable.seq() function
INSERT INTO _test_state SELECT durable.start(
    durable.seq(
        durable.seq(
            'INSERT INTO test_sequence_log (step, variant) VALUES (1, ''fn'')',
            'INSERT INTO test_sequence_log (step, variant) VALUES (2, ''fn'')'
        ),
        'INSERT INTO test_sequence_log (step, variant) VALUES (3, ''fn'')'
    ),
    'test-sequence-fn'
), 'function';

DO $$
DECLARE
    rec RECORD;
    status TEXT;
    steps INT[];
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
        
        -- Check steps for this variant
        IF rec.variant = 'operator' THEN
            SELECT array_agg(step ORDER BY id) INTO steps 
            FROM test_sequence_log WHERE variant = 'op';
        ELSE
            SELECT array_agg(step ORDER BY id) INTO steps 
            FROM test_sequence_log WHERE variant = 'fn';
        END IF;
        
        IF steps != ARRAY[1,2,3] THEN
            RAISE EXCEPTION 'TEST FAILED [%]: expected [1,2,3], got %', rec.variant, steps;
        END IF;
        
        RAISE NOTICE 'PASSED: sequence [%]', rec.variant;
    END LOOP;
    
    RAISE NOTICE 'TEST PASSED: sequence (both variants)';
END $$;

DROP TABLE _test_state;
DROP TABLE test_sequence_log;
SELECT 'TEST PASSED' AS result;
