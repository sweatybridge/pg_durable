-- Scenario Test: Complex AI Document Pipeline
-- Demonstrates: loop, race, conditional, join, sleep, variables
-- 
-- Pipeline: Process documents in batches with timeout protection,
-- parallel embedding + classification, conditional quality check,
-- and rate-limited batch processing loop.

-- Setup: Create tables
DROP TABLE IF EXISTS ai_results CASCADE;
DROP TABLE IF EXISTS ai_docs CASCADE;

CREATE TABLE ai_docs (
    id SERIAL PRIMARY KEY,
    content TEXT,
    embedding FLOAT[],
    classification TEXT,
    quality_score FLOAT,
    status TEXT DEFAULT 'pending',
    error_msg TEXT,
    created_at TIMESTAMP DEFAULT now()
);

CREATE TABLE ai_results (
    id SERIAL PRIMARY KEY,
    batch_num INT,
    docs_processed INT,
    docs_failed INT,
    created_at TIMESTAMP DEFAULT now()
);

-- Seed test documents
INSERT INTO ai_docs (content) VALUES
('PostgreSQL is a powerful open-source database'),
('Machine learning enables pattern recognition'),
('Cloud computing provides scalable infrastructure'),
('Data pipelines automate ETL processes'),
('Vector databases enable semantic search');

-- Mock: Generate embedding (simulates slow AI call)
CREATE OR REPLACE FUNCTION mock_embed(doc_id INT) RETURNS INT AS $$
BEGIN
    PERFORM pg_sleep(0.1);  -- Simulate API latency
    UPDATE ai_docs SET embedding = ARRAY[random(), random(), random(), random()]
    WHERE id = doc_id;
    RETURN doc_id;
END;
$$ LANGUAGE plpgsql;

-- Mock: Classify document (simulates AI classification)
CREATE OR REPLACE FUNCTION mock_classify(doc_id INT) RETURNS INT AS $$
DECLARE
    doc_content TEXT;
BEGIN
    SELECT content INTO doc_content FROM ai_docs WHERE id = doc_id;
    UPDATE ai_docs SET classification = CASE
        WHEN doc_content ILIKE '%database%' OR doc_content ILIKE '%sql%' THEN 'database'
        WHEN doc_content ILIKE '%machine%' OR doc_content ILIKE '%learning%' THEN 'ml'
        WHEN doc_content ILIKE '%cloud%' THEN 'cloud'
        ELSE 'general'
    END
    WHERE id = doc_id;
    RETURN doc_id;
END;
$$ LANGUAGE plpgsql;

-- Mock: Quality check (returns score 0-1)
CREATE OR REPLACE FUNCTION mock_quality_check(doc_id INT) RETURNS FLOAT AS $$
DECLARE
    score FLOAT;
BEGIN
    score := 0.5 + random() * 0.5;  -- Random 0.5-1.0
    UPDATE ai_docs SET quality_score = score WHERE id = doc_id;
    RETURN score;
END;
$$ LANGUAGE plpgsql;

-- Mock: Process a single document with all steps
-- Returns: 1 = success, 0 = failed quality check, -1 = error
CREATE OR REPLACE FUNCTION mock_process_doc(doc_id INT) RETURNS INT AS $$
DECLARE
    qual FLOAT;
BEGIN
    -- Run embedding and classification in parallel (simulated here sequentially)
    PERFORM mock_embed(doc_id);
    PERFORM mock_classify(doc_id);
    
    -- Quality check
    qual := mock_quality_check(doc_id);
    
    IF qual >= 0.6 THEN
        UPDATE ai_docs SET status = 'completed' WHERE id = doc_id;
        RETURN 1;
    ELSE
        UPDATE ai_docs SET status = 'low_quality', error_msg = 'Quality below threshold' WHERE id = doc_id;
        RETURN 0;
    END IF;
EXCEPTION WHEN OTHERS THEN
    UPDATE ai_docs SET status = 'failed', error_msg = SQLERRM WHERE id = doc_id;
    RETURN -1;
END;
$$ LANGUAGE plpgsql;

-- Mock: Process batch and return stats
CREATE OR REPLACE FUNCTION mock_process_batch(batch_size INT, batch_num INT) RETURNS TABLE(processed INT, failed INT) AS $$
DECLARE
    doc RECORD;
    result INT;
    p_count INT := 0;
    f_count INT := 0;
BEGIN
    FOR doc IN 
        SELECT id FROM ai_docs WHERE status = 'pending' LIMIT batch_size FOR UPDATE SKIP LOCKED
    LOOP
        result := mock_process_doc(doc.id);
        IF result = 1 THEN
            p_count := p_count + 1;
        ELSE
            f_count := f_count + 1;
        END IF;
    END LOOP;
    
    INSERT INTO ai_results (batch_num, docs_processed, docs_failed) 
    VALUES (batch_num, p_count, f_count);
    
    processed := p_count;
    failed := f_count;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

-- Count remaining docs
CREATE OR REPLACE FUNCTION count_pending_docs() RETURNS INT AS $$
    SELECT COUNT(*)::INT FROM ai_docs WHERE status = 'pending';
$$ LANGUAGE SQL;

CREATE TEMP TABLE _test_state (instance_id TEXT);

-- Complex AI Pipeline using all control flow operators
-- Pattern: Check pending -> conditional batch process -> rate limit -> repeat
INSERT INTO _test_state SELECT df.start(
    -- Step 1: Check if there are pending documents
    'SELECT count_pending_docs() as cnt' |=> 'pending'
    
    -- Step 2: Conditional - only process if there are pending docs
    ~> (
        'SELECT $pending > 0'
            ?> (
                -- Process batch with timeout protection (race)
                (
                    'SELECT * FROM mock_process_batch(2, 1)' |=> 'batch1'
                    | df.sleep(30)  -- 30 second timeout per batch
                )
                -- Rate limit between batches
                ~> df.sleep(1)
                -- Second batch
                ~> (
                    'SELECT * FROM mock_process_batch(2, 2)' |=> 'batch2'
                    | df.sleep(30)
                )
                ~> df.sleep(1)
                -- Final batch (remaining)
                ~> 'SELECT * FROM mock_process_batch(10, 3)' |=> 'batch3'
            )
            !> 'SELECT ''no_docs'' as result'
    )
    
    -- Final summary
    ~> 'SELECT SUM(docs_processed) as total_processed, SUM(docs_failed) as total_failed FROM ai_results',
    'ai-doc-pipeline'
);

DO $$
DECLARE
    inst_id TEXT;
    inst_status TEXT;
    total_docs INT;
    completed_docs INT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    RAISE NOTICE 'Testing complex AI pipeline: %', inst_id;
    
    LOOP
        SELECT s INTO inst_status FROM df.status(inst_id) s;
        EXIT WHEN lower(inst_status) IN ('completed', 'failed', 'canceled') OR attempts > 500;
        PERFORM pg_sleep(0.2);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(inst_status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: pipeline status = %, output = %', 
            inst_status, (SELECT output FROM df.instance_info(inst_id));
    END IF;
    
    -- Verify documents were processed
    SELECT COUNT(*) INTO total_docs FROM ai_docs;
    SELECT COUNT(*) INTO completed_docs FROM ai_docs WHERE status IN ('completed', 'low_quality');
    
    IF completed_docs < total_docs THEN
        RAISE EXCEPTION 'TEST FAILED: expected % docs processed, got %', total_docs, completed_docs;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: ai_pipeline (% docs processed)', completed_docs;
END $$;

-- Cleanup
DROP TABLE _test_state;
DROP TABLE ai_results;
DROP TABLE ai_docs;
DROP FUNCTION mock_embed(INT);
DROP FUNCTION mock_classify(INT);
DROP FUNCTION mock_quality_check(INT);
DROP FUNCTION mock_process_doc(INT);
DROP FUNCTION mock_process_batch(INT, INT);
DROP FUNCTION count_pending_docs();
SELECT 'TEST PASSED' AS result;

