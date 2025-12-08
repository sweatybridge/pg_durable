-- Scenario Test: Parallel Execution
-- Based on USER_GUIDE.md Example 5: Parallel Execution
-- Tests parallel counting of users and orders simultaneously

-- Clear logs from previous runs
DELETE FROM playground.logs WHERE msg LIKE '%Parallel counts%';

CREATE TEMP TABLE _test_state (instance_id TEXT);

-- Parallel counts: count users and orders concurrently, then log completion
INSERT INTO _test_state SELECT df.start(
    df.join(
        'SELECT COUNT(*) as user_count FROM playground.users',
        'SELECT COUNT(*) as order_count FROM playground.orders'
    )
    ~> 'INSERT INTO playground.logs (msg) VALUES (''Parallel counts complete'')',
    'scenario-parallel-counts'
);

DO $$
DECLARE
    inst_id TEXT;
    inst_status TEXT;
    log_count INT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    RAISE NOTICE 'Testing parallel counts: %', inst_id;
    
    LOOP
        SELECT s INTO inst_status FROM df.status(inst_id) s;
        IF attempts % 50 = 0 THEN
            RAISE NOTICE 'Status after % attempts: %', attempts, inst_status;
        END IF;
        EXIT WHEN inst_status IN ('Completed', 'completed', 'Failed', 'failed', 'Canceled', 'canceled', 'ContinuedAsNew') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(inst_status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: parallel counts status = %', inst_status;
    END IF;
    
    -- Verify the log entry was created
    SELECT COUNT(*) INTO log_count 
    FROM playground.logs WHERE msg LIKE '%Parallel counts complete%';
    IF log_count < 1 THEN
        RAISE EXCEPTION 'TEST FAILED: expected completion log entry, got %', log_count;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: scenario_parallel_counts';
END $$;

DROP TABLE _test_state;
SELECT 'TEST PASSED' AS result;
