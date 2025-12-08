-- Scenario Test: AI Worker with Continuous Processing Loop
-- Demonstrates: @> loop, race timeout, conditional retry, parallel health checks
--
-- Pattern: An AI inference worker that:
-- 1. Polls for jobs continuously
-- 2. Processes with timeout protection  
-- 3. Retries failed jobs conditionally
-- 4. Runs parallel health checks
-- 5. Gets cancelled gracefully

-- Setup: Create tables
DROP TABLE IF EXISTS worker_health CASCADE;
DROP TABLE IF EXISTS worker_jobs CASCADE;

CREATE TABLE worker_jobs (
    id SERIAL PRIMARY KEY,
    input_data TEXT,
    output_data TEXT,
    attempts INT DEFAULT 0,
    max_attempts INT DEFAULT 3,
    status TEXT DEFAULT 'pending',
    error_msg TEXT,
    created_at TIMESTAMP DEFAULT now(),
    processed_at TIMESTAMP
);

CREATE TABLE worker_health (
    id SERIAL PRIMARY KEY,
    metric TEXT,
    value INT,
    recorded_at TIMESTAMP DEFAULT now()
);

-- Seed some jobs
INSERT INTO worker_jobs (input_data) VALUES
('Analyze sentiment: Great product!'),
('Analyze sentiment: Terrible service'),
('Analyze sentiment: Its okay'),
('Analyze sentiment: Love it!');

-- Mock: Process a single job (may fail randomly for testing retries)
CREATE OR REPLACE FUNCTION mock_inference(job_id INT) RETURNS TEXT AS $$
DECLARE
    input TEXT;
    result TEXT;
BEGIN
    UPDATE worker_jobs SET attempts = attempts + 1, status = 'processing' WHERE id = job_id;
    SELECT input_data INTO input FROM worker_jobs WHERE id = job_id;
    
    -- Simulate occasional failures (fail if attempts < 2 and random)
    IF (SELECT attempts FROM worker_jobs WHERE id = job_id) < 2 AND random() < 0.3 THEN
        UPDATE worker_jobs SET status = 'failed', error_msg = 'Transient error' WHERE id = job_id;
        RETURN 'FAILED';
    END IF;
    
    -- Determine sentiment
    IF input ILIKE '%great%' OR input ILIKE '%love%' THEN
        result := 'positive';
    ELSIF input ILIKE '%terrible%' THEN
        result := 'negative';
    ELSE
        result := 'neutral';
    END IF;
    
    UPDATE worker_jobs SET output_data = result, status = 'completed', processed_at = now() 
    WHERE id = job_id;
    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- Mock: Get next job to process (pending or failed with retries left)
CREATE OR REPLACE FUNCTION get_next_job() RETURNS INT AS $$
DECLARE
    next_id INT;
BEGIN
    SELECT id INTO next_id FROM worker_jobs 
    WHERE status = 'pending' OR (status = 'failed' AND attempts < max_attempts)
    ORDER BY 
        CASE WHEN status = 'failed' THEN 1 ELSE 2 END,  -- Retry failures first
        created_at
    LIMIT 1
    FOR UPDATE SKIP LOCKED;
    RETURN next_id;
END;
$$ LANGUAGE plpgsql;

-- Mock: Record health metric
CREATE OR REPLACE FUNCTION record_health(metric TEXT, value INT) RETURNS VOID AS $$
BEGIN
    INSERT INTO worker_health (metric, value) VALUES (metric, value);
END;
$$ LANGUAGE plpgsql;

-- Mock: Check job counts for health reporting
CREATE OR REPLACE FUNCTION get_job_counts() RETURNS TABLE(pending INT, completed INT, failed INT) AS $$
BEGIN
    RETURN QUERY SELECT 
        (SELECT COUNT(*)::INT FROM worker_jobs WHERE status = 'pending'),
        (SELECT COUNT(*)::INT FROM worker_jobs WHERE status = 'completed'),
        (SELECT COUNT(*)::INT FROM worker_jobs WHERE status = 'failed' AND attempts >= max_attempts);
END;
$$ LANGUAGE plpgsql;

CREATE TEMP TABLE _test_state (instance_id TEXT);

-- AI Worker Loop - processes jobs until cancelled
-- Uses: @> loop, race timeout, conditional processing, parallel health
INSERT INTO _test_state SELECT df.start(
    @> (
        -- Get next job (may be null if queue empty)
        'SELECT get_next_job() as job' |=> 'job_id'
        
        -- Conditional: process if job exists, else just wait
        ~> (
            'SELECT $job_id IS NOT NULL'
                ?> (
                    -- Process with 5 second timeout (race)
                    (
                        'SELECT mock_inference($job_id) as result' |=> 'inference_result'
                        | df.sleep(5)  -- Timeout protection
                    )
                    -- Record completion health metric
                    ~> 'SELECT record_health(''job_completed'', 1)'
                )
                !> (
                    -- No jobs - record idle and wait longer
                    'SELECT record_health(''idle_tick'', 1)'
                )
        )
        
        -- Rate limit: wait between iterations
        ~> df.sleep(1)
        
        -- Parallel health checks every iteration
        ~> (
            'SELECT record_health(''loop_tick'', 1)'
            & 'SELECT * FROM get_job_counts()' |=> 'counts'
        )
    ),
    'ai-worker-loop'
);

-- Let it process for a few seconds, then cancel
SELECT pg_sleep(8);

DO $$
DECLARE
    inst_id TEXT;
    inst_status TEXT;
    completed_jobs INT;
    health_ticks INT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    RAISE NOTICE 'Cancelling AI worker: %', inst_id;
    
    -- Cancel the loop
    PERFORM df.cancel(inst_id, 'Test complete');
    
    -- Wait for cancellation
    LOOP
        SELECT s INTO inst_status FROM df.status(inst_id) s;
        EXIT WHEN lower(inst_status) IN ('canceled', 'cancelled') OR attempts > 100;
        PERFORM pg_sleep(0.2);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(inst_status) NOT IN ('canceled', 'cancelled') THEN
        RAISE EXCEPTION 'TEST FAILED: expected cancelled, got %', inst_status;
    END IF;
    
    -- Verify some jobs were processed
    SELECT COUNT(*) INTO completed_jobs FROM worker_jobs WHERE status = 'completed';
    IF completed_jobs < 1 THEN
        RAISE EXCEPTION 'TEST FAILED: expected at least 1 completed job, got %', completed_jobs;
    END IF;
    
    -- Verify health metrics recorded (proves loop ran)
    SELECT COUNT(*) INTO health_ticks FROM worker_health WHERE metric = 'loop_tick';
    IF health_ticks < 1 THEN
        RAISE EXCEPTION 'TEST FAILED: expected health ticks, got %', health_ticks;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: ai_worker (% jobs, % ticks)', completed_jobs, health_ticks;
END $$;

-- Cleanup
DROP TABLE _test_state;
DROP TABLE worker_health;
DROP TABLE worker_jobs;
DROP FUNCTION mock_inference(INT);
DROP FUNCTION get_next_job();
DROP FUNCTION record_health(TEXT, INT);
DROP FUNCTION get_job_counts();
SELECT 'TEST PASSED' AS result;

