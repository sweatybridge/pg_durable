# Implementing pgai Vectorizer Scenarios with pg_durable

This guide shows how to implement the core scenarios from [pgai Vectorizer](https://github.com/timescale/pgai/blob/main/docs/vectorizer/api-reference.md) using pg_durable primitives. Instead of using the pgai extension, we build equivalent functionality with durable SQL functions.

---

## Table of Contents

1. [Overview](#overview)
2. [Schema Setup](#schema-setup)
3. [Core Scenarios](#core-scenarios)
   - [Automated Embedding Generation](#1-automated-embedding-generation)
   - [Automatic Synchronization](#2-automatic-synchronization)
   - [Background Processing](#3-background-processing)
   - [Batch Processing](#4-batch-processing)
   - [Chunking Strategies](#5-chunking-strategies)
   - [Formatting Templates](#6-formatting-templates)
   - [Queue Management](#7-queue-management)
   - [Monitoring & Status](#8-monitoring--status)
4. [Complete Vectorizer Implementation](#complete-vectorizer-implementation)
5. [Advanced Patterns](#advanced-patterns)

---

## Overview

pgai Vectorizer provides these key capabilities:
- **Automated embedding generation** for table data
- **Automatic synchronization** via triggers when source data changes
- **Background processing** that runs asynchronously
- **Batch processing** for efficient handling of large datasets
- **Configurable chunking** to split text into manageable pieces
- **Formatting templates** to combine multiple fields
- **Queue management** for processing pending items
- **Monitoring** to track vectorizer status and queue depth

We'll implement each of these using pg_durable's primitives:
- `df.sql()` - Execute SQL statements
- `~>` - Sequence steps
- `&` / `df.join()` - Parallel execution
- `df.if()` - Conditional logic
- `df.loop()` / `@>` - Infinite loops for background processing
- `df.sleep()` - Delays between batches
- `df.wait_for_schedule()` - Cron-style scheduling
- `|=>` - Variable substitution between steps

---

## Schema Setup

First, create the schema to support our vectorizer implementation:

```sql
-- Schema for vectorizer infrastructure
CREATE SCHEMA IF NOT EXISTS vectorizer;

-- Vectorizer configuration table
CREATE TABLE vectorizer.config (
    id SERIAL PRIMARY KEY,
    name TEXT UNIQUE NOT NULL,
    source_schema TEXT NOT NULL,
    source_table TEXT NOT NULL,
    source_pk TEXT NOT NULL DEFAULT 'id',
    content_column TEXT NOT NULL,
    embedding_table TEXT NOT NULL,
    embedding_column TEXT NOT NULL DEFAULT 'embedding',
    dimensions INT NOT NULL DEFAULT 1536,
    chunk_size INT DEFAULT 512,
    chunk_overlap INT DEFAULT 50,
    format_template TEXT,
    batch_size INT DEFAULT 100,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Queue table for pending embeddings
CREATE TABLE vectorizer.queue (
    id SERIAL PRIMARY KEY,
    vectorizer_id INT REFERENCES vectorizer.config(id),
    source_pk TEXT NOT NULL,
    operation TEXT NOT NULL, -- 'INSERT', 'UPDATE', 'DELETE'
    queued_at TIMESTAMPTZ DEFAULT now(),
    processing BOOLEAN DEFAULT false,
    UNIQUE(vectorizer_id, source_pk)
);

-- Processing log
CREATE TABLE vectorizer.log (
    id SERIAL PRIMARY KEY,
    vectorizer_id INT REFERENCES vectorizer.config(id),
    batch_size INT,
    processed INT,
    errors INT DEFAULT 0,
    duration_ms INT,
    processed_at TIMESTAMPTZ DEFAULT now()
);

-- Indexes
CREATE INDEX idx_queue_pending ON vectorizer.queue(vectorizer_id, queued_at) 
    WHERE NOT processing;
CREATE INDEX idx_queue_vectorizer ON vectorizer.queue(vectorizer_id);
```

---

## Core Scenarios

### 1. Automated Embedding Generation

**pgai Scenario**: Automatically generate embeddings when data is inserted.

**pg_durable Implementation**: A durable function that processes the embedding queue.

```sql
-- Generate embedding for a single record
-- This calls an external embedding API (OpenAI, Ollama, etc.)
CREATE OR REPLACE FUNCTION vectorizer.generate_embedding(
    content TEXT,
    dimensions INT DEFAULT 1536
) RETURNS vector AS $$
DECLARE
    result vector;
BEGIN
    -- Option 1: Use pgvector + pg_ai for OpenAI
    -- SELECT openai_embed('text-embedding-3-small', content, dimensions) INTO result;
    
    -- Option 2: Use http extension to call API directly
    -- SELECT (http_post(...))::vector INTO result;
    
    -- Option 3: Placeholder - replace with actual implementation
    -- For demo, create a random vector
    SELECT array_agg(random())::vector INTO result
    FROM generate_series(1, dimensions);
    
    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- Process a single item from the queue
SELECT df.start(
    -- Get next pending item
    'SELECT q.id, q.source_pk, c.source_schema, c.source_table, 
            c.content_column, c.embedding_table, c.dimensions, c.format_template
     FROM vectorizer.queue q
     JOIN vectorizer.config c ON c.id = q.vectorizer_id
     WHERE NOT q.processing AND c.is_active
     ORDER BY q.queued_at
     LIMIT 1
     FOR UPDATE SKIP LOCKED' |=> 'item'
    
    ~> df.if(
        'SELECT $item IS NOT NULL',
        
        -- Mark as processing
        'UPDATE vectorizer.queue SET processing = true WHERE id = ($item).id'
        
        -- Get content from source table
        ~> 'SELECT content FROM ' || ($item).source_schema || '.' || ($item).source_table ||
           ' WHERE ' || ($item).source_pk || ' = ($item).source_pk' |=> 'content'
        
        -- Generate embedding
        ~> 'SELECT vectorizer.generate_embedding($content, ($item).dimensions)' |=> 'embedding'
        
        -- Store embedding
        ~> 'INSERT INTO ' || ($item).embedding_table || ' (source_pk, embedding, created_at)
            VALUES (($item).source_pk, $embedding, now())
            ON CONFLICT (source_pk) DO UPDATE SET embedding = EXCLUDED.embedding'
        
        -- Remove from queue
        ~> 'DELETE FROM vectorizer.queue WHERE id = ($item).id',
        
        -- Nothing to process
        'SELECT ''queue empty'''
    ),
    'process-single-embedding'
);
```

### 2. Automatic Synchronization

**pgai Scenario**: Triggers automatically queue changes when source data changes.

**pg_durable Implementation**: Create a trigger function and a durable sync loop.

```sql
-- Trigger function to queue changes
CREATE OR REPLACE FUNCTION vectorizer.queue_change() RETURNS TRIGGER AS $$
DECLARE
    vec_id INT;
    pk_value TEXT;
BEGIN
    -- Find the vectorizer for this table
    SELECT id INTO vec_id 
    FROM vectorizer.config 
    WHERE source_schema = TG_TABLE_SCHEMA 
      AND source_table = TG_TABLE_NAME
      AND is_active;
    
    IF vec_id IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    
    -- Get primary key value
    IF TG_OP = 'DELETE' THEN
        EXECUTE format('SELECT ($1).%I::text', 
            (SELECT source_pk FROM vectorizer.config WHERE id = vec_id))
        INTO pk_value USING OLD;
    ELSE
        EXECUTE format('SELECT ($1).%I::text', 
            (SELECT source_pk FROM vectorizer.config WHERE id = vec_id))
        INTO pk_value USING NEW;
    END IF;
    
    -- Queue the change
    INSERT INTO vectorizer.queue (vectorizer_id, source_pk, operation)
    VALUES (vec_id, pk_value, TG_OP)
    ON CONFLICT (vectorizer_id, source_pk) 
    DO UPDATE SET operation = EXCLUDED.operation, queued_at = now(), processing = false;
    
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

-- Helper to install trigger on a source table
CREATE OR REPLACE FUNCTION vectorizer.install_trigger(
    schema_name TEXT,
    table_name TEXT
) RETURNS void AS $$
DECLARE
    trigger_name TEXT;
BEGIN
    trigger_name := 'vectorizer_sync_' || schema_name || '_' || table_name;
    
    EXECUTE format(
        'DROP TRIGGER IF EXISTS %I ON %I.%I',
        trigger_name, schema_name, table_name
    );
    
    EXECUTE format(
        'CREATE TRIGGER %I 
         AFTER INSERT OR UPDATE OR DELETE ON %I.%I
         FOR EACH ROW EXECUTE FUNCTION vectorizer.queue_change()',
        trigger_name, schema_name, table_name
    );
END;
$$ LANGUAGE plpgsql;

-- Durable function to continuously sync changes
SELECT df.start(
    @> (
        -- Check for pending changes
        'SELECT COUNT(*) FROM vectorizer.queue WHERE NOT processing' |=> 'pending'
        
        ~> df.if(
            'SELECT $pending > 0',
            -- Process pending items (call the batch processor)
            'SELECT df.start(
                ''SELECT vectorizer.process_batch(100)'',
                ''sync-batch-'' || now()::text
            )',
            -- Nothing pending, wait a bit
            df.sleep(5)
        )
    ),
    'vectorizer-sync-loop'
);
```

### 3. Background Processing

**pgai Scenario**: Embeddings are generated asynchronously in the background.

**pg_durable Implementation**: An eternal loop that processes the queue.

```sql
-- Background worker that continuously processes embeddings
SELECT df.start(
    @> (
        -- Wait for scheduled interval (every 10 seconds)
        df.sleep(10)
        
        -- Check if there's work to do
        ~> 'SELECT COUNT(*) FROM vectorizer.queue 
            WHERE NOT processing' |=> 'queue_depth'
        
        ~> df.if(
            'SELECT $queue_depth > 0',
            
            -- Process a batch
            'WITH batch AS (
                SELECT q.id, q.vectorizer_id, q.source_pk, q.operation,
                       c.source_schema, c.source_table, c.content_column,
                       c.embedding_table, c.dimensions
                FROM vectorizer.queue q
                JOIN vectorizer.config c ON c.id = q.vectorizer_id
                WHERE NOT q.processing AND c.is_active
                ORDER BY q.queued_at
                LIMIT 50
                FOR UPDATE OF q SKIP LOCKED
            ),
            marked AS (
                UPDATE vectorizer.queue SET processing = true
                WHERE id IN (SELECT id FROM batch)
                RETURNING id
            )
            SELECT json_agg(batch.*) FROM batch' |=> 'items'
            
            -- Process each item (simplified - real impl would batch API calls)
            ~> 'SELECT vectorizer.process_items($items::json)'
            
            -- Log the batch
            ~> 'INSERT INTO vectorizer.log (vectorizer_id, batch_size, processed)
                SELECT vectorizer_id, COUNT(*), COUNT(*)
                FROM json_to_recordset($items::json) AS x(vectorizer_id int)
                GROUP BY vectorizer_id',
            
            -- Nothing to do
            'SELECT ''idle'''
        )
    ),
    'vectorizer-background-worker'
);
```

### 4. Batch Processing

**pgai Scenario**: Process data in configurable batches for efficiency.

**pg_durable Implementation**: Batch processing with parallel API calls.

```sql
-- Batch processor function
CREATE OR REPLACE FUNCTION vectorizer.process_batch(batch_size INT DEFAULT 100)
RETURNS TABLE(processed INT, errors INT, duration_ms INT) AS $$
DECLARE
    start_time TIMESTAMPTZ;
    items_processed INT := 0;
    items_errored INT := 0;
    item RECORD;
BEGIN
    start_time := clock_timestamp();
    
    FOR item IN 
        WITH batch AS (
            SELECT q.id, q.vectorizer_id, q.source_pk, q.operation,
                   c.source_schema, c.source_table, c.content_column,
                   c.embedding_table, c.dimensions, c.format_template
            FROM vectorizer.queue q
            JOIN vectorizer.config c ON c.id = q.vectorizer_id
            WHERE NOT q.processing AND c.is_active
            ORDER BY q.queued_at
            LIMIT batch_size
            FOR UPDATE OF q SKIP LOCKED
        ),
        marked AS (
            UPDATE vectorizer.queue SET processing = true
            WHERE id IN (SELECT id FROM batch)
        )
        SELECT * FROM batch
    LOOP
        BEGIN
            -- Handle based on operation type
            IF item.operation = 'DELETE' THEN
                EXECUTE format(
                    'DELETE FROM %I WHERE source_pk = $1',
                    item.embedding_table
                ) USING item.source_pk;
            ELSE
                -- Get content and generate embedding
                PERFORM vectorizer.process_single_item(item);
            END IF;
            
            -- Remove from queue
            DELETE FROM vectorizer.queue WHERE id = item.id;
            items_processed := items_processed + 1;
            
        EXCEPTION WHEN OTHERS THEN
            -- Mark as not processing so it can be retried
            UPDATE vectorizer.queue SET processing = false WHERE id = item.id;
            items_errored := items_errored + 1;
        END;
    END LOOP;
    
    RETURN QUERY SELECT 
        items_processed, 
        items_errored,
        EXTRACT(MILLISECONDS FROM clock_timestamp() - start_time)::INT;
END;
$$ LANGUAGE plpgsql;

-- Durable batch processing with configurable size
SELECT df.start(
    -- Get batch size from config
    'SELECT COALESCE(MAX(batch_size), 100) FROM vectorizer.config 
     WHERE is_active' |=> 'batch_size'
    
    -- Process batch
    ~> 'SELECT * FROM vectorizer.process_batch($batch_size)' |=> 'result'
    
    -- Log results
    ~> 'INSERT INTO vectorizer.log (batch_size, processed, errors, duration_ms)
        VALUES ($batch_size, ($result).processed, ($result).errors, ($result).duration_ms)',
    
    'process-embedding-batch'
);

-- Parallel batch processing for multiple vectorizers
SELECT df.start(
    -- Get all active vectorizers
    'SELECT array_agg(id) FROM vectorizer.config WHERE is_active' |=> 'vec_ids'
    
    -- Process each vectorizer in parallel (up to 3 concurrent)
    ~> df.join3(
        'SELECT vectorizer.process_batch_for_vectorizer(($vec_ids)[1], 100)',
        'SELECT vectorizer.process_batch_for_vectorizer(($vec_ids)[2], 100)',
        'SELECT vectorizer.process_batch_for_vectorizer(($vec_ids)[3], 100)'
    ),
    'parallel-batch-processing'
);
```

### 5. Chunking Strategies

**pgai Scenario**: Split text into smaller chunks before embedding.

**pg_durable Implementation**: Chunking functions and chunk processing.

```sql
-- Character text splitter
CREATE OR REPLACE FUNCTION vectorizer.chunk_text(
    content TEXT,
    chunk_size INT DEFAULT 512,
    chunk_overlap INT DEFAULT 50,
    separator TEXT DEFAULT E'\n'
) RETURNS TABLE(chunk_index INT, chunk_text TEXT) AS $$
DECLARE
    chunks TEXT[];
    current_chunk TEXT := '';
    words TEXT[];
    word TEXT;
    i INT := 0;
BEGIN
    -- Split by separator first
    words := string_to_array(content, separator);
    
    FOREACH word IN ARRAY words LOOP
        IF length(current_chunk) + length(word) + 1 > chunk_size THEN
            -- Emit current chunk
            i := i + 1;
            RETURN QUERY SELECT i, current_chunk;
            
            -- Start new chunk with overlap
            IF chunk_overlap > 0 AND length(current_chunk) > chunk_overlap THEN
                current_chunk := right(current_chunk, chunk_overlap) || separator || word;
            ELSE
                current_chunk := word;
            END IF;
        ELSE
            IF current_chunk = '' THEN
                current_chunk := word;
            ELSE
                current_chunk := current_chunk || separator || word;
            END IF;
        END IF;
    END LOOP;
    
    -- Emit final chunk
    IF current_chunk != '' THEN
        i := i + 1;
        RETURN QUERY SELECT i, current_chunk;
    END IF;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Recursive character text splitter (mimics LangChain)
CREATE OR REPLACE FUNCTION vectorizer.chunk_text_recursive(
    content TEXT,
    chunk_size INT DEFAULT 512,
    chunk_overlap INT DEFAULT 50,
    separators TEXT[] DEFAULT ARRAY[E'\n\n', E'\n', '. ', ' ']
) RETURNS TABLE(chunk_index INT, chunk_text TEXT) AS $$
DECLARE
    sep TEXT;
    parts TEXT[];
    part TEXT;
    current_chunk TEXT := '';
    i INT := 0;
BEGIN
    -- Try each separator in order
    FOREACH sep IN ARRAY separators LOOP
        IF position(sep in content) > 0 THEN
            parts := string_to_array(content, sep);
            
            FOREACH part IN ARRAY parts LOOP
                IF length(current_chunk) + length(part) + length(sep) > chunk_size THEN
                    IF current_chunk != '' THEN
                        i := i + 1;
                        RETURN QUERY SELECT i, trim(current_chunk);
                    END IF;
                    
                    -- Handle overlap
                    IF chunk_overlap > 0 AND length(current_chunk) > chunk_overlap THEN
                        current_chunk := right(current_chunk, chunk_overlap);
                    ELSE
                        current_chunk := '';
                    END IF;
                END IF;
                
                IF current_chunk = '' THEN
                    current_chunk := part;
                ELSE
                    current_chunk := current_chunk || sep || part;
                END IF;
            END LOOP;
            
            IF current_chunk != '' THEN
                i := i + 1;
                RETURN QUERY SELECT i, trim(current_chunk);
            END IF;
            
            RETURN;
        END IF;
    END LOOP;
    
    -- No separator found, return as single chunk or split by character
    IF length(content) <= chunk_size THEN
        RETURN QUERY SELECT 1, content;
    ELSE
        FOR i IN 1..ceil(length(content)::float / chunk_size)::int LOOP
            RETURN QUERY SELECT i, 
                substring(content FROM (i-1)*chunk_size + 1 FOR chunk_size);
        END LOOP;
    END IF;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Durable function to process content with chunking
SELECT df.start(
    -- Get record to process
    'SELECT id, content FROM blog_posts WHERE id = $1' |=> 'record'
    
    -- Get chunk settings
    ~> 'SELECT chunk_size, chunk_overlap FROM vectorizer.config 
        WHERE source_table = ''blog_posts''' |=> 'settings'
    
    -- Generate chunks
    ~> 'SELECT array_agg(row_to_json(c)) 
        FROM vectorizer.chunk_text_recursive(
            ($record).content, 
            ($settings).chunk_size, 
            ($settings).chunk_overlap
        ) c' |=> 'chunks'
    
    -- Process each chunk (generate embedding)
    ~> 'INSERT INTO blog_post_embeddings (source_id, chunk_index, chunk_text, embedding)
        SELECT 
            ($record).id,
            (c->>''chunk_index'')::int,
            c->>''chunk_text'',
            vectorizer.generate_embedding(c->>''chunk_text'')
        FROM json_array_elements($chunks::json) c',
    
    'process-chunked-content'
);
```

### 6. Formatting Templates

**pgai Scenario**: Combine multiple fields using templates before embedding.

**pg_durable Implementation**: Template formatting function.

```sql
-- Format content using a template
CREATE OR REPLACE FUNCTION vectorizer.format_content(
    template TEXT,
    record JSONB
) RETURNS TEXT AS $$
DECLARE
    result TEXT := template;
    key TEXT;
    value TEXT;
BEGIN
    -- Replace $fieldname with actual values
    FOR key, value IN SELECT * FROM jsonb_each_text(record) LOOP
        result := replace(result, '$' || key, COALESCE(value, ''));
    END LOOP;
    
    -- Handle $chunk placeholder (will be replaced during chunking)
    -- result := replace(result, '$chunk', record->>'_chunk_text');
    
    RETURN result;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Durable function with template formatting
SELECT df.start(
    -- Get record as JSON
    'SELECT row_to_json(p.*) as data 
     FROM blog_posts p WHERE id = $1' |=> 'record'
    
    -- Get template from config
    ~> 'SELECT format_template FROM vectorizer.config 
        WHERE source_table = ''blog_posts''' |=> 'template'
    
    -- Format content
    ~> 'SELECT vectorizer.format_content($template, ($record).data::jsonb)' |=> 'formatted'
    
    -- Generate embedding for formatted content
    ~> 'SELECT vectorizer.generate_embedding($formatted)' |=> 'embedding'
    
    -- Store
    ~> 'INSERT INTO blog_post_embeddings (source_id, embedding, formatted_content)
        VALUES ((($record).data->>''id'')::int, $embedding, $formatted)',
    
    'process-with-template'
);

-- Example: Create vectorizer with formatting
INSERT INTO vectorizer.config (
    name, source_schema, source_table, content_column, 
    embedding_table, format_template
) VALUES (
    'blog_posts_vectorizer',
    'public',
    'blog_posts', 
    'content',
    'blog_post_embeddings',
    'Title: $title
Author: $author
Published: $published_at

$content'
);
```

### 7. Queue Management

**pgai Scenario**: Manage pending items in the vectorizer queue.

**pg_durable Implementation**: Queue management functions and monitoring.

```sql
-- Get queue depth for a vectorizer
CREATE OR REPLACE FUNCTION vectorizer.queue_pending(
    vectorizer_name TEXT,
    exact_count BOOLEAN DEFAULT false
) RETURNS BIGINT AS $$
DECLARE
    vec_id INT;
    count_val BIGINT;
BEGIN
    SELECT id INTO vec_id FROM vectorizer.config WHERE name = vectorizer_name;
    
    IF exact_count THEN
        SELECT COUNT(*) INTO count_val 
        FROM vectorizer.queue 
        WHERE vectorizer_id = vec_id AND NOT processing;
    ELSE
        -- Approximate count for large queues
        SELECT CASE 
            WHEN c > 10000 THEN 9223372036854775807
            ELSE c
        END INTO count_val
        FROM (
            SELECT COUNT(*) as c FROM vectorizer.queue 
            WHERE vectorizer_id = vec_id AND NOT processing
            LIMIT 10001
        ) x;
    END IF;
    
    RETURN count_val;
END;
$$ LANGUAGE plpgsql;

-- Durable queue processor with adaptive batch sizing
SELECT df.start(
    @> (
        -- Check queue depth
        'SELECT vectorizer.queue_pending(''blog_posts_vectorizer'')' |=> 'pending'
        
        ~> df.if(
            'SELECT $pending > 1000',
            -- High load: process larger batches faster
            'SELECT vectorizer.process_batch(500)' ~> df.sleep(1),
            
            df.if(
                'SELECT $pending > 100',
                -- Medium load: normal batches
                'SELECT vectorizer.process_batch(100)' ~> df.sleep(5),
                
                df.if(
                    'SELECT $pending > 0',
                    -- Low load: small batches, longer sleep
                    'SELECT vectorizer.process_batch(50)' ~> df.sleep(10),
                    -- No work: sleep longer
                    df.sleep(30)
                )
            )
        )
    ),
    'adaptive-queue-processor'
);

-- Priority queue processing (process high-priority items first)
SELECT df.start(
    @> (
        -- Check for high-priority items (recently updated)
        'SELECT COUNT(*) FROM vectorizer.queue q
         JOIN vectorizer.config c ON c.id = q.vectorizer_id
         WHERE NOT q.processing 
         AND q.operation = ''UPDATE''
         AND q.queued_at > now() - interval ''1 minute''' |=> 'urgent'
        
        ~> df.if(
            'SELECT $urgent > 0',
            -- Process urgent items immediately
            'WITH urgent_batch AS (
                SELECT q.id FROM vectorizer.queue q
                WHERE NOT q.processing AND q.operation = ''UPDATE''
                AND q.queued_at > now() - interval ''1 minute''
                LIMIT 50
                FOR UPDATE SKIP LOCKED
            )
            UPDATE vectorizer.queue SET processing = true
            WHERE id IN (SELECT id FROM urgent_batch)'
            ~> 'SELECT vectorizer.process_batch(50)',
            
            -- Normal processing
            df.sleep(5)
            ~> 'SELECT vectorizer.process_batch(100)'
        )
    ),
    'priority-queue-processor'
);
```

### 8. Monitoring & Status

**pgai Scenario**: Monitor vectorizer status and performance.

**pg_durable Implementation**: Status views and monitoring loops.

```sql
-- Vectorizer status view
CREATE OR REPLACE VIEW vectorizer.status AS
SELECT 
    c.id,
    c.name,
    c.source_schema || '.' || c.source_table as source_table,
    c.embedding_table as target_table,
    c.is_active,
    COALESCE(q.pending, 0) as pending_items,
    COALESCE(q.processing, 0) as processing_items,
    l.last_processed_at,
    l.last_batch_size,
    l.last_duration_ms
FROM vectorizer.config c
LEFT JOIN (
    SELECT 
        vectorizer_id,
        COUNT(*) FILTER (WHERE NOT processing) as pending,
        COUNT(*) FILTER (WHERE processing) as processing
    FROM vectorizer.queue
    GROUP BY vectorizer_id
) q ON q.vectorizer_id = c.id
LEFT JOIN LATERAL (
    SELECT 
        processed_at as last_processed_at,
        batch_size as last_batch_size,
        duration_ms as last_duration_ms
    FROM vectorizer.log 
    WHERE vectorizer_id = c.id
    ORDER BY processed_at DESC
    LIMIT 1
) l ON true;

-- Durable monitoring with alerting
SELECT df.start(
    @> (
        df.wait_for_schedule('*/5 * * * *')  -- Every 5 minutes
        
        -- Collect status
        ~> 'SELECT json_agg(row_to_json(s)) FROM vectorizer.status s' |=> 'status'
        
        -- Store metrics
        ~> 'INSERT INTO vectorizer.metrics (data, recorded_at)
            VALUES ($status::jsonb, now())'
        
        -- Check for issues
        ~> 'SELECT COUNT(*) FROM vectorizer.status 
            WHERE pending_items > 5000' |=> 'backlogged'
        
        ~> 'SELECT COUNT(*) FROM vectorizer.status 
            WHERE is_active AND last_processed_at < now() - interval ''1 hour''' |=> 'stalled'
        
        -- Alert if issues found
        ~> df.if(
            'SELECT $backlogged > 0 OR $stalled > 0',
            'INSERT INTO alerts (type, severity, message, details)
             VALUES (
                 ''vectorizer'',
                 CASE WHEN $stalled > 0 THEN ''critical'' ELSE ''warning'' END,
                 ''Vectorizer issues detected'',
                 jsonb_build_object(
                     ''backlogged'', $backlogged,
                     ''stalled'', $stalled,
                     ''status'', $status::jsonb
                 )
             )',
            'SELECT ''all healthy'''
        )
    ),
    'vectorizer-monitor'
);

-- Detailed instance monitoring
SELECT df.start(
    -- Get specific vectorizer status
    'SELECT * FROM vectorizer.status WHERE name = ''blog_posts_vectorizer''' |=> 'status'
    
    -- Get recent processing history
    ~> 'SELECT json_agg(row_to_json(l))
        FROM (
            SELECT processed_at, batch_size, processed, errors, duration_ms
            FROM vectorizer.log
            WHERE vectorizer_id = ($status).id
            ORDER BY processed_at DESC
            LIMIT 10
        ) l' |=> 'history'
    
    -- Calculate throughput
    ~> 'SELECT 
            COALESCE(SUM(processed), 0) as total_processed,
            COALESCE(AVG(duration_ms), 0) as avg_duration_ms,
            COALESCE(SUM(processed) / NULLIF(SUM(duration_ms), 0) * 1000, 0) as items_per_sec
        FROM vectorizer.log
        WHERE vectorizer_id = ($status).id
        AND processed_at > now() - interval ''1 hour''' |=> 'metrics'
    
    -- Return comprehensive status
    ~> 'SELECT jsonb_build_object(
            ''status'', row_to_json($status),
            ''history'', $history::jsonb,
            ''metrics'', row_to_json($metrics)
        )::text',
    
    'get-vectorizer-details'
);
```

---

## Complete Vectorizer Implementation

Here's a complete implementation that ties all the pieces together:

```sql
-- ============================================================================
-- STEP 1: Create a new vectorizer
-- ============================================================================

CREATE OR REPLACE FUNCTION vectorizer.create(
    p_name TEXT,
    p_source_schema TEXT,
    p_source_table TEXT,
    p_content_column TEXT,
    p_embedding_table TEXT DEFAULT NULL,
    p_dimensions INT DEFAULT 1536,
    p_chunk_size INT DEFAULT NULL,
    p_chunk_overlap INT DEFAULT 50,
    p_format_template TEXT DEFAULT NULL,
    p_batch_size INT DEFAULT 100
) RETURNS INT AS $$
DECLARE
    vec_id INT;
    emb_table TEXT;
BEGIN
    -- Default embedding table name
    emb_table := COALESCE(p_embedding_table, p_source_table || '_embeddings');
    
    -- Create config entry
    INSERT INTO vectorizer.config (
        name, source_schema, source_table, content_column,
        embedding_table, dimensions, chunk_size, chunk_overlap,
        format_template, batch_size
    ) VALUES (
        p_name, p_source_schema, p_source_table, p_content_column,
        emb_table, p_dimensions, p_chunk_size, p_chunk_overlap,
        p_format_template, p_batch_size
    ) RETURNING id INTO vec_id;
    
    -- Create embedding table
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I (
            id SERIAL PRIMARY KEY,
            source_pk TEXT NOT NULL,
            chunk_index INT DEFAULT 0,
            chunk_text TEXT,
            embedding vector(%s),
            created_at TIMESTAMPTZ DEFAULT now(),
            UNIQUE(source_pk, chunk_index)
        )',
        emb_table, p_dimensions
    );
    
    -- Create index on embedding
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS %I ON %I 
         USING hnsw (embedding vector_cosine_ops)',
        emb_table || '_embedding_idx', emb_table
    );
    
    -- Install trigger
    PERFORM vectorizer.install_trigger(p_source_schema, p_source_table);
    
    -- Queue existing records for initial embedding
    EXECUTE format(
        'INSERT INTO vectorizer.queue (vectorizer_id, source_pk, operation)
         SELECT %s, %I::text, ''INSERT'' FROM %I.%I',
        vec_id, 'id', p_source_schema, p_source_table
    );
    
    RETURN vec_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- STEP 2: Start the background processor
-- ============================================================================

-- Main background worker
SELECT df.start(
    @> (
        -- Get all active vectorizers
        'SELECT array_agg(id) FROM vectorizer.config WHERE is_active' |=> 'vec_ids'
        
        -- Check total queue depth
        ~> 'SELECT SUM(pending_items) FROM vectorizer.status' |=> 'total_pending'
        
        ~> df.if(
            'SELECT $total_pending > 0',
            
            -- Process in parallel for each vectorizer (max 3)
            df.if(
                'SELECT array_length($vec_ids, 1) >= 3',
                df.join3(
                    'SELECT vectorizer.process_batch_for_vectorizer(($vec_ids)[1])',
                    'SELECT vectorizer.process_batch_for_vectorizer(($vec_ids)[2])',
                    'SELECT vectorizer.process_batch_for_vectorizer(($vec_ids)[3])'
                ),
                df.if(
                    'SELECT array_length($vec_ids, 1) = 2',
                    df.join(
                        'SELECT vectorizer.process_batch_for_vectorizer(($vec_ids)[1])',
                        'SELECT vectorizer.process_batch_for_vectorizer(($vec_ids)[2])'
                    ),
                    'SELECT vectorizer.process_batch_for_vectorizer(($vec_ids)[1])'
                )
            )
            
            -- Short sleep between batches
            ~> df.sleep(2),
            
            -- Nothing to do, longer sleep
            df.sleep(30)
        )
    ),
    'vectorizer-main-worker'
);

-- ============================================================================
-- STEP 3: Enable monitoring
-- ============================================================================

SELECT df.start(
    @> (
        df.wait_for_schedule('*/5 * * * *')
        
        -- Collect and store metrics
        ~> 'INSERT INTO vectorizer.metrics (
                vectorizer_id, pending_items, processing_rate, recorded_at
            )
            SELECT 
                c.id,
                COALESCE(q.cnt, 0),
                COALESCE(l.rate, 0),
                now()
            FROM vectorizer.config c
            LEFT JOIN (
                SELECT vectorizer_id, COUNT(*) as cnt
                FROM vectorizer.queue WHERE NOT processing
                GROUP BY vectorizer_id
            ) q ON q.vectorizer_id = c.id
            LEFT JOIN (
                SELECT vectorizer_id, 
                       SUM(processed)::float / NULLIF(SUM(duration_ms), 0) * 1000 as rate
                FROM vectorizer.log
                WHERE processed_at > now() - interval ''5 minutes''
                GROUP BY vectorizer_id
            ) l ON l.vectorizer_id = c.id'
    ),
    'vectorizer-metrics-collector'
);

-- ============================================================================
-- STEP 4: Usage Example
-- ============================================================================

-- Create a vectorizer for blog posts
SELECT vectorizer.create(
    p_name => 'blog_posts_vectorizer',
    p_source_schema => 'public',
    p_source_table => 'blog_posts',
    p_content_column => 'content',
    p_dimensions => 1536,
    p_chunk_size => 512,
    p_chunk_overlap => 50,
    p_format_template => 'Title: $title\n\n$content',
    p_batch_size => 100
);

-- Insert some data (trigger will automatically queue for embedding)
INSERT INTO blog_posts (title, content) VALUES 
('Hello World', 'This is my first blog post about PostgreSQL and embeddings.');

-- Check status
SELECT * FROM vectorizer.status WHERE name = 'blog_posts_vectorizer';

-- Query embeddings with similarity search
SELECT bp.title, bp.content, 1 - (e.embedding <=> query_embedding) as similarity
FROM blog_posts bp
JOIN blog_posts_embeddings e ON e.source_pk = bp.id::text
CROSS JOIN (SELECT vectorizer.generate_embedding('PostgreSQL tutorials') as query_embedding) q
ORDER BY e.embedding <=> q.query_embedding
LIMIT 5;
```

---

## Advanced Patterns

### Retry Failed Embeddings

```sql
SELECT df.start(
    @> (
        df.wait_for_schedule('0 * * * *')  -- Every hour
        
        -- Find stuck items (processing for too long)
        ~> 'UPDATE vectorizer.queue 
            SET processing = false 
            WHERE processing = true 
            AND queued_at < now() - interval ''30 minutes''
            RETURNING COUNT(*)' |=> 'unstuck'
        
        ~> df.if(
            'SELECT $unstuck > 0',
            'INSERT INTO vectorizer.log (vectorizer_id, batch_size, errors)
             VALUES (0, 0, $unstuck)',  -- Log as system event
            'SELECT ''no stuck items'''
        )
    ),
    'vectorizer-retry-stuck'
);
```

### Enable/Disable Vectorizer

```sql
-- Disable
SELECT df.start(
    'UPDATE vectorizer.config SET is_active = false 
     WHERE name = ''blog_posts_vectorizer''',
    'disable-vectorizer'
);

-- Enable
SELECT df.start(
    'UPDATE vectorizer.config SET is_active = true 
     WHERE name = ''blog_posts_vectorizer''',
    'enable-vectorizer'
);
```

### Drop Vectorizer

```sql
SELECT df.start(
    -- Get vectorizer info
    'SELECT id, source_schema, source_table, embedding_table 
     FROM vectorizer.config WHERE name = $1' |=> 'vec'
    
    -- Remove trigger
    ~> 'DROP TRIGGER IF EXISTS vectorizer_sync_' || ($vec).source_schema || '_' || ($vec).source_table ||
       ' ON ' || ($vec).source_schema || '.' || ($vec).source_table
    
    -- Clear queue
    ~> 'DELETE FROM vectorizer.queue WHERE vectorizer_id = ($vec).id'
    
    -- Delete config
    ~> 'DELETE FROM vectorizer.config WHERE id = ($vec).id'
    
    -- Optionally drop embedding table
    -- ~> 'DROP TABLE IF EXISTS ' || ($vec).embedding_table
    ,
    'drop-vectorizer'
);
```

---

## Summary

This implementation provides all key pgai Vectorizer capabilities using pg_durable primitives:

| pgai Feature | pg_durable Implementation |
|--------------|---------------------------|
| Automated embedding generation | `@>` loop with `df.sql()` to process queue |
| Automatic synchronization | PostgreSQL triggers + queue table |
| Background processing | Eternal loop (`@>`) with `df.sleep()` |
| Batch processing | `df.sql()` with `LIMIT` and `FOR UPDATE SKIP LOCKED` |
| Chunking strategies | Custom `vectorizer.chunk_text_recursive()` function |
| Formatting templates | Custom `vectorizer.format_content()` function |
| Queue management | Queue table + status view + adaptive processor |
| Monitoring | `df.wait_for_schedule()` + metrics collection |

The durable function approach provides:
- **Fault tolerance**: Processing survives crashes and restarts
- **Visibility**: Monitor progress via `df.status()` and `df.explain()`
- **Flexibility**: Easy to customize chunking, formatting, and batch sizes
- **Observability**: Built-in logging and metrics collection

