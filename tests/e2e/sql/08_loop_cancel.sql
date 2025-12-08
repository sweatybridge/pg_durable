-- Test: Loop execution and cancellation
-- Tests df.loop() function and @> operator
-- Expected: Loop runs multiple iterations, then stops on cancel

DROP TABLE IF EXISTS test_loop_log;
CREATE TABLE test_loop_log (id SERIAL, iteration INT, variant TEXT, ts TIMESTAMP DEFAULT now());

CREATE TEMP TABLE _test_state (instance_id TEXT, variant TEXT);

-- Variant A: df.loop() function
INSERT INTO _test_state SELECT df.start(
    df.loop(
        'INSERT INTO test_loop_log (iteration, variant) VALUES ((SELECT COALESCE(MAX(iteration), 0) + 1 FROM test_loop_log WHERE variant = ''func''), ''func'')'
        ~> df.sleep(1)
    ),
    'test-loop-func'
), 'func';

-- Variant B: @> operator
INSERT INTO _test_state SELECT df.start(
    @> (
        'INSERT INTO test_loop_log (iteration, variant) VALUES ((SELECT COALESCE(MAX(iteration), 0) + 1 FROM test_loop_log WHERE variant = ''op''), ''op'')'
        ~> df.sleep(1)
    ),
    'test-loop-op'
), 'op';

DO $$
DECLARE
    rec RECORD;
    status TEXT;
    cnt INT;
    attempts INT;
BEGIN
    FOR rec IN SELECT instance_id, variant FROM _test_state LOOP
        RAISE NOTICE 'Testing % variant: %', rec.variant, rec.instance_id;
        attempts := 0;
        
        -- Wait for at least 2 iterations
        LOOP
            SELECT COUNT(*) INTO cnt FROM test_loop_log WHERE variant = rec.variant;
            EXIT WHEN cnt >= 2 OR attempts > 100;
            PERFORM pg_sleep(0.5);
            attempts := attempts + 1;
        END LOOP;
        
        IF cnt < 2 THEN
            RAISE EXCEPTION 'TEST FAILED [%]: expected at least 2 iterations, got %', rec.variant, cnt;
        END IF;
        
        -- Cancel the loop
        PERFORM df.cancel(rec.instance_id, 'Test complete');
        
        -- Wait for cancellation
        attempts := 0;
        LOOP
            SELECT s INTO status FROM df.status(rec.instance_id) s;
            EXIT WHEN lower(status) IN ('canceled', 'cancelled', 'failed') OR attempts > 100;
            PERFORM pg_sleep(0.2);
            attempts := attempts + 1;
        END LOOP;
        
        IF lower(status) NOT IN ('canceled', 'cancelled') THEN
            RAISE EXCEPTION 'TEST FAILED [%]: expected Canceled, got %', rec.variant, status;
        END IF;
        
        RAISE NOTICE 'PASSED: loop_cancel [%]', rec.variant;
    END LOOP;
    
    RAISE NOTICE 'TEST PASSED: loop_cancel (func + @> operator)';
END $$;

DROP TABLE _test_state;
DROP TABLE test_loop_log;
SELECT 'TEST PASSED' AS result;
