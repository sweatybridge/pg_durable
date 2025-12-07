# pg_durable User Guide (Future Vision)

**Durable SQL Functions for PostgreSQL**

> ⚠️ **FUTURE DOCUMENT**: This shows what pg_durable will look like with proposed operators. Not all operators are implemented yet.

pg_durable is a PostgreSQL extension that brings durable, fault-tolerant function execution directly into your database. Define durable SQL functions using a SQL-native DSL, and let the extension handle persistence, retries, and scheduling.

---

## Table of Contents

1. [Overview](#overview)
2. [Getting Started](#getting-started)
3. [Core Concepts](#core-concepts)
4. [DSL Reference](#dsl-reference)
5. [Function Examples](#function-examples)
6. [Loops & Cron Jobs](#loops--cron-jobs)
7. [Visualizing Functions](#visualizing-functions)
8. [Monitoring](#monitoring)

---

## Overview

### What is pg_durable?

pg_durable enables you to define and execute **durable SQL functions** entirely within PostgreSQL. Unlike traditional job queues or external workflow engines, pg_durable:

- **Lives in your database** - No external services to manage
- **Uses SQL syntax** - Define functions with familiar SQL operators
- **Is fault-tolerant** - Functions survive crashes and restarts
- **Supports scheduling** - Built-in cron-style scheduling for recurring jobs
- **Provides visibility** - Monitor function status directly via SQL queries

### Key Features

| Feature | Description |
|---------|-------------|
| **SQL DSL** | Define functions using plain SQL with intuitive operators |
| **Sequential Execution** | Chain steps with `~>` operator |
| **Parallel Execution** | Run steps concurrently with `&` and `\|` operators |
| **Conditional Logic** | Branch with `?>` and `!>` operators |
| **Timers & Delays** | Sleep with `durable.sleep()` |
| **Cron Scheduling** | Schedule with `durable.wait_for_schedule()` |
| **Eternal Loops** | Create forever-running jobs with `@>` operator |
| **Variable Substitution** | Pass results between steps using `$name` |
| **Visualization** | Preview function structure with `durable.explain()` |

---

## Getting Started

### Enable the Extension

```sql
CREATE EXTENSION pg_durable;
```

### Your First Durable Function

```sql
-- Execute a simple SQL query as a durable function
SELECT durable.start('SELECT ''Hello, durable world!''');
-- Returns: a1b2c3d4 (8-character instance ID)
```

---

## DSL Reference

### Auto-Wrap SQL

Plain SQL strings are automatically wrapped - no need for explicit `durable.sql()` calls:

```sql
-- These are equivalent:
'SELECT 1' ~> 'SELECT 2'
durable.sql('SELECT 1') ~> durable.sql('SELECT 2')
```

### Operators

| Operator | Name | Description | Example |
|----------|------|-------------|---------|
| `~>` | Sequence | Run left, then right | `'SELECT 1' ~> 'SELECT 2'` |
| `\|=>` | Name | Name result for `$var` reference | `'SELECT 1' \|=> 'myvar'` |
| `&` | Join | Run in parallel, wait for all | `'SELECT 1' & 'SELECT 2'` |
| `\|` | Race | Run in parallel, first wins | `api_call \| durable.sleep(30)` |
| `?>` | If-Then | Conditional then branch | `cond ?> then_branch` |
| `!>` | Else | Conditional else branch | `cond ?> then !> else` |
| `@>` | Loop | Repeat forever | `@> body` |

### Functions

| Function | Description | Example |
|----------|-------------|---------|
| `durable.sleep(seconds)` | Pause for N seconds | `durable.sleep(60)` |
| `durable.wait_for_schedule(cron)` | Wait until cron matches | `durable.wait_for_schedule('0 * * * *')` |
| `durable.start(func, label)` | Start function | `durable.start('SELECT 1', 'job')` |
| `durable.cancel(id, reason)` | Cancel function | `durable.cancel('a1b2c3d4', 'Done')` |
| `durable.explain(input)` | Visualize graph | `durable.explain('a1b2c3d4')` |

### Variable Substitution

Use `$name` to reference named results in subsequent steps:

```sql
SELECT durable.start(
    'SELECT 100 as amount' |=> 'total'
    ~> 'SELECT $total * 2 as doubled'
);
```

---

## Function Examples

### 1. Simple Query

```sql
SELECT durable.start(
    'SELECT COUNT(*) FROM users WHERE active = true',
    'count-active-users'
);
```

### 2. Sequential Steps

```sql
SELECT durable.start(
    'INSERT INTO logs (msg) VALUES (''Step 1'')'
    ~> 'INSERT INTO logs (msg) VALUES (''Step 2'')'
    ~> 'INSERT INTO logs (msg) VALUES (''Step 3'')',
    'three-step-job'
);
```

### 3. Parallel Execution with `&`

**Before (verbose):**
```sql
SELECT durable.start(
    durable.join(
        'SELECT COUNT(*) FROM users',
        'SELECT COUNT(*) FROM orders'
    ),
    'parallel-counts'
);
```

**After (with `&` operator):**
```sql
SELECT durable.start(
    ('SELECT COUNT(*) FROM users' |=> 'user_count')
    & ('SELECT COUNT(*) FROM orders' |=> 'order_count'),
    'parallel-counts'
);
```

### 4. Three-Way Parallel

```sql
SELECT durable.start(
    'SELECT sync_users()' 
    & 'SELECT sync_orders()' 
    & 'SELECT sync_products()',
    'parallel-sync'
);
```

### 5. Race with Timeout using `|`

**Before (verbose):**
```sql
-- No direct race support
```

**After (with `|` operator):**
```sql
SELECT durable.start(
    'SELECT fetch_from_api()'              -- the actual work
    | (durable.sleep(30) ~> 'SELECT ''timeout'''),  -- timeout fallback
    'api-with-timeout'
);
```

### 6. Conditional Logic with `?>` and `!>`

**Before (verbose):**
```sql
SELECT durable.start(
    durable.if(
        'SELECT COUNT(*) > 3 FROM task_queue WHERE status = ''pending''',
        'INSERT INTO logs (msg) VALUES (''High load!'')',
        'INSERT INTO logs (msg) VALUES (''Normal load'')'
    ),
    'check-load'
);
```

**After (with `?>` and `!>` operators):**
```sql
SELECT durable.start(
    'SELECT COUNT(*) > 3 FROM task_queue WHERE status = ''pending'''
        ?> 'INSERT INTO logs (msg) VALUES (''High load!'')'
        !> 'INSERT INTO logs (msg) VALUES (''Normal load'')',
    'check-load'
);
```

### 7. Complex Conditional with Variables

```sql
SELECT durable.start(
    'SELECT id, amount FROM orders WHERE status = ''pending'' LIMIT 1' |=> 'order'
    ~> 'SELECT $order IS NOT NULL'
        ?> (
            'UPDATE orders SET status = ''processing'' WHERE id = $order.id'
            ~> durable.sleep(2)
            ~> 'UPDATE orders SET status = ''completed'' WHERE id = $order.id'
        )
        !> 'SELECT ''no pending orders''',
    'process-order'
);
```

### 8. ETL with Parallel Validation

```sql
SELECT durable.start(
    'SELECT * FROM staging WHERE status = ''new'' LIMIT 1' |=> 'record'
    ~> 'SELECT $record IS NOT NULL'
        ?> (
            -- Validate schema AND rules in parallel
            ('SELECT validate_schema($record)' |=> 'schema_ok')
            & ('SELECT validate_rules($record)' |=> 'rules_ok')
            ~> 'SELECT $schema_ok AND $rules_ok'
                ?> 'INSERT INTO target SELECT * FROM staging WHERE id = $record.id'
                !> 'UPDATE staging SET status = ''invalid'' WHERE id = $record.id'
        )
        !> 'SELECT ''no records to process''',
    'etl-with-validation'
);
```

---

## Loops & Cron Jobs

### Eternal Loops with `@>`

**Before (verbose):**
```sql
SELECT durable.start(
    durable.loop(
        'INSERT INTO heartbeats (ts) VALUES (now())'
        ~> durable.sleep(30)
    ),
    'heartbeat'
);
```

**After (with `@>` operator):**
```sql
SELECT durable.start(
    @> (
        'INSERT INTO heartbeats (ts) VALUES (now())'
        ~> durable.sleep(30)
    ),
    'heartbeat'
);
```

### Cron-Style Scheduling

```sql
-- Every minute tick
SELECT durable.start(
    @> (
        durable.wait_for_schedule('* * * * *')
        ~> 'INSERT INTO logs (msg) VALUES (''tick'')'
    ),
    'every-minute'
);

-- Every 5 minutes: check pending tasks
SELECT durable.start(
    @> (
        durable.wait_for_schedule('*/5 * * * *')
        ~> 'SELECT COUNT(*) FROM tasks WHERE status = ''pending''' |=> 'pending'
        ~> 'SELECT $pending > 10'
            ?> 'INSERT INTO alerts (msg) VALUES (''Task backlog!'')'
            !> 'SELECT ''ok'''
    ),
    'task-monitor'
);

-- Daily at midnight: archive old orders with conditional logging
SELECT durable.start(
    @> (
        durable.wait_for_schedule('0 0 * * *')
        ~> 'SELECT COUNT(*) FROM orders 
            WHERE status = ''completed'' 
            AND processed_at < now() - interval ''7 days''' |=> 'count'
        ~> 'SELECT $count > 0'
            ?> (
                'UPDATE orders SET status = ''archived'' 
                 WHERE status = ''completed'' 
                 AND processed_at < now() - interval ''7 days''' |=> 'archived'
                ~> 'INSERT INTO logs (msg) VALUES (''Archived '' || $archived || '' orders'')'
            )
            !> 'INSERT INTO logs (msg) VALUES (''No orders to archive'')'
    ),
    'daily-order-archive'
);

-- Weekdays at 9am: generate report
SELECT durable.start(
    @> (
        durable.wait_for_schedule('0 9 * * 1-5')
        ~> 'SELECT generate_report(''daily_summary'')'
    ),
    'weekday-report'
);
```

### Parallel Processing in a Loop

```sql
-- Process batches with parallel workers
SELECT durable.start(
    @> (
        durable.wait_for_schedule('*/10 * * * *')
        ~> 'SELECT * FROM queue WHERE status = ''pending'' LIMIT 3' |=> 'batch'
        ~> 'SELECT array_length($batch, 1) > 0'
            ?> (
                'SELECT process($batch[0])' 
                & 'SELECT process($batch[1])' 
                & 'SELECT process($batch[2])'
            )
            !> durable.sleep(60)
    ),
    'parallel-batch-processor'
);
```

---

## Advanced Patterns

### Retry with Exponential Backoff (using race)

```sql
SELECT durable.start(
    -- Try API call with timeout, retry on failure
    ('SELECT call_external_api()' | (durable.sleep(5) ~> 'SELECT ''timeout''')) |=> 'result'
    ~> 'SELECT $result != ''timeout'''
        ?> 'INSERT INTO results VALUES ($result)'
        !> (
            durable.sleep(10)
            ~> ('SELECT call_external_api()' | (durable.sleep(10) ~> 'SELECT ''timeout2''')) |=> 'retry'
            ~> 'SELECT $retry != ''timeout2'''
                ?> 'INSERT INTO results VALUES ($retry)'
                !> 'INSERT INTO failures VALUES (''API unreachable'')'
        ),
    'api-with-retry'
);
```

### Fan-Out/Fan-In Pattern

```sql
SELECT durable.start(
    'SELECT * FROM customers WHERE needs_sync' |=> 'customers'
    ~> (
        'SELECT sync_to_crm($customers)' |=> 'crm_result'
        & 'SELECT sync_to_billing($customers)' |=> 'billing_result'
        & 'SELECT sync_to_analytics($customers)' |=> 'analytics_result'
    )
    ~> 'UPDATE customers SET synced_at = now() WHERE id IN (SELECT id FROM $customers)',
    'fan-out-sync'
);
```

### Conditional Parallel vs Sequential

```sql
SELECT durable.start(
    'SELECT current_load()' |=> 'load'
    ~> 'SELECT $load < 0.5'   -- low load?
        ?> (
            -- Parallel when load is low
            'SELECT heavy_task_a()' & 'SELECT heavy_task_b()'
        )
        !> (
            -- Sequential when load is high
            'SELECT heavy_task_a()' ~> 'SELECT heavy_task_b()'
        ),
    'adaptive-processing'
);
```

---

## Comparison: Old vs New Syntax

### Simple Conditional

| Old | New |
|-----|-----|
| `durable.if(cond, then, else)` | `cond ?> then !> else` |

```sql
-- Old
durable.if('SELECT x > 0', 'SELECT ''positive''', 'SELECT ''negative''')

-- New
'SELECT x > 0' ?> 'SELECT ''positive''' !> 'SELECT ''negative'''
```

### Parallel Join

| Old | New |
|-----|-----|
| `durable.join(a, b)` | `a & b` |

```sql
-- Old
durable.join('SELECT 1', 'SELECT 2', 'SELECT 3')

-- New
'SELECT 1' & 'SELECT 2' & 'SELECT 3'
```

### Loop

| Old | New |
|-----|-----|
| `durable.loop(body)` | `@> body` |

```sql
-- Old
durable.loop(
    durable.sleep(60) ~> 'SELECT heartbeat()'
)

-- New
@> (durable.sleep(60) ~> 'SELECT heartbeat()')
```

### Complex Example

**Old (verbose):**
```sql
SELECT durable.start(
    durable.loop(
        durable.wait_for_schedule('0 * * * *')
        ~> durable.if(
            'SELECT COUNT(*) > 0 FROM pending',
            durable.join(
                'SELECT process_batch_a()',
                'SELECT process_batch_b()'
            )
            ~> 'INSERT INTO logs VALUES (''done'')',
            'SELECT ''nothing to do'''
        )
    ),
    'hourly-processor'
);
```

**New (with operators):**
```sql
SELECT durable.start(
    @> (
        durable.wait_for_schedule('0 * * * *')
        ~> 'SELECT COUNT(*) > 0 FROM pending'
            ?> (
                ('SELECT process_batch_a()' & 'SELECT process_batch_b()')
                ~> 'INSERT INTO logs VALUES (''done'')'
            )
            !> 'SELECT ''nothing to do'''
    ),
    'hourly-processor'
);
```

---

## Operator Precedence

| Precedence | Operator | Description |
|------------|----------|-------------|
| 1 (highest) | `\|=>` | Name result |
| 2 | `~>` | Sequence |
| 3 | `&` | Parallel join |
| 4 | `\|` | Race |
| 5 | `?>` | If-then |
| 6 (lowest) | `!>` | Else |
| prefix | `@>` | Loop |

Use parentheses to clarify complex expressions:

```sql
-- Parallel first, then sequence
('SELECT a()' & 'SELECT b()') ~> 'SELECT c()'

-- Race with timeout
'SELECT slow_api()' | (durable.sleep(30) ~> 'SELECT ''timeout''')

-- Conditional with parallel branches
'SELECT condition()'
    ?> ('SELECT a()' & 'SELECT b()')
    !> 'SELECT fallback()'
```

---

## Quick Reference Card

```sql
-- Sequence
'SELECT 1' ~> 'SELECT 2' ~> 'SELECT 3'

-- Name result
'SELECT 1' |=> 'myvar' ~> 'SELECT $myvar * 2'

-- Parallel (join)
'SELECT a()' & 'SELECT b()' & 'SELECT c()'

-- Race (first wins)
'SELECT slow()' | (durable.sleep(30) ~> 'SELECT ''timeout''')

-- Conditional
'SELECT x > 0' ?> 'SELECT ''yes''' !> 'SELECT ''no'''

-- Loop forever
@> (durable.sleep(60) ~> 'SELECT heartbeat()')

-- Cron job
@> (
    durable.wait_for_schedule('0 * * * *')
    ~> 'SELECT hourly_task()'
)

-- Complex: hourly job with conditional parallel processing
@> (
    durable.wait_for_schedule('0 * * * *')
    ~> 'SELECT has_work()' 
        ?> ('SELECT job_a()' & 'SELECT job_b()')
        !> 'SELECT ''idle'''
)
```

---

## Implementation Status

| Operator | Status | Function Equivalent |
|----------|--------|---------------------|
| `~>` | ✅ Implemented | `durable.then(a, b)` |
| `\|=>` | ✅ Implemented | `durable.as(name, a)` |
| `&` | 🔮 Proposed | `durable.join(a, b)` |
| `\|` | 🔮 Proposed | `durable.race(a, b)` |
| `?>` / `!>` | 🔮 Proposed | `durable.if(cond, then, else)` |
| `@>` | 🔮 Proposed | `durable.loop(body)` |

