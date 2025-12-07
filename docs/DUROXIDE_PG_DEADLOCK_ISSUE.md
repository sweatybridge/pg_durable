# Duroxide-PG Deadlock Issue in Parallel Operations

## Summary

When using `duroxide-pg` (PostgreSQL provider for Duroxide) with parallel operations like `JOIN`, a deadlock can occur in the `fetch_orchestration_item` function when multiple workers attempt to acquire locks on the `instance_locks` table simultaneously.

## Environment

- **PostgreSQL**: 17.7 (Debian 17.7-3.pgdg12+1)
- **Duroxide**: Latest (via duroxide-pg crate)
- **Platform**: linux/amd64 (running on Docker)
- **Schema**: `duroxide` (custom schema for duroxide tables)

## Problem Description

When executing a durable function with parallel branches (using `durable.join()`), the Duroxide runtime spawns multiple workers to process each branch concurrently. These workers call `duroxide.fetch_orchestration_item()` to acquire work items.

The deadlock occurs when:
1. Worker A calls `fetch_orchestration_item` and begins acquiring a lock
2. Worker B calls `fetch_orchestration_item` and begins acquiring a lock
3. Both workers end up waiting for each other's transaction to complete
4. PostgreSQL detects the deadlock and aborts one transaction

After the deadlock resolution, the orchestration instance appears to get stuck in a "pending" state and never completes.

## Reproduction Code

### Simple JOIN (2 branches)

```sql
-- Create test table
DROP TABLE IF EXISTS test_parallel_log;
CREATE TABLE test_parallel_log (id SERIAL, branch TEXT, ts TIMESTAMP DEFAULT now());

-- Start a durable function with parallel JOIN
SELECT durable.start(
    durable.join(
        'INSERT INTO test_parallel_log (branch) VALUES (''A'')',
        'INSERT INTO test_parallel_log (branch) VALUES (''B'')'
    ),
    'test-parallel-deadlock'
);

-- Check status (will stay "pending" when deadlock occurs)
SELECT durable.status('instance_id_here');
```

### JOIN with 3 branches

```sql
SELECT durable.start(
    durable.join3(
        'INSERT INTO test_parallel_log (branch) VALUES (''A'')',
        'INSERT INTO test_parallel_log (branch) VALUES (''B'')',
        'INSERT INTO test_parallel_log (branch) VALUES (''C'')'
    ),
    'test-join3-deadlock'
);
```

### JOIN followed by sequence

```sql
SELECT durable.start(
    durable.join(
        'SELECT COUNT(*) FROM playground.users',
        'SELECT COUNT(*) FROM playground.orders'
    )
    ~> 'INSERT INTO playground.logs (msg) VALUES (''Parallel counts complete'')',
    'test-join-sequence-deadlock'
);
```

## Logs

### Deadlock Detection Log

```
2025-12-07 21:59:56.770 UTC [76] ERROR:  deadlock detected
2025-12-07 21:59:56.770 UTC [76] DETAIL:  Process 76 waits for ShareLock on transaction 794; blocked by process 79.
	Process 79 waits for ShareLock on transaction 795; blocked by process 76.
	Process 76: SELECT * FROM duroxide.fetch_orchestration_item($1, $2)
	Process 79: SELECT * FROM duroxide.fetch_orchestration_item($1, $2)
2025-12-07 21:59:56.770 UTC [76] HINT:  See server log for query details.
2025-12-07 21:59:56.770 UTC [76] CONTEXT:  while inserting index tuple (0,12) in relation "instance_locks"
	SQL statement "INSERT INTO duroxide.instance_locks (instance_id, lock_token, locked_until, locked_at)
	            VALUES (v_instance_id, v_lock_token, v_locked_until, p_now_ms)
	            ON CONFLICT(instance_id) DO UPDATE
	            SET lock_token = EXCLUDED.lock_token,
	                locked_until = EXCLUDED.locked_until,
	                locked_at = EXCLUDED.locked_at
	            WHERE duroxide.instance_locks.locked_until <= p_now_ms"
	PL/pgSQL function duroxide.fetch_orchestration_item(bigint,bigint) line 28 at SQL statement
2025-12-07 21:59:56.770 UTC [76] STATEMENT:  SELECT * FROM duroxide.fetch_orchestration_item($1, $2)
```

### Slow Query Warning (post-deadlock)

```
[2m2025-12-07T21:59:56.787686Z[0m [33m WARN[0m [2msqlx::query[0m[2m:[0m slow statement: execution time exceeded alert threshold 
    [3msummary[0m[2m=[0m"SELECT * FROM duroxide.fetch_orchestration_item($1, …)" 
    [3mdb.statement[0m[2m=[0m"\n\nSELECT\n  *\nFROM\n  duroxide.fetch_orchestration_item($1, $2)\n" 
    [3mrows_affected[0m[2m=[0m0 
    [3mrows_returned[0m[2m=[0m0 
    [3melapsed[0m[2m=[0m1.008913542s 
    [3melapsed_secs[0m[2m=[0m1.008913542 
    [3mslow_threshold[0m[2m=[0m1s

[2m2025-12-07T21:59:56.789412Z[0m [33m WARN[0m [2msqlx::query[0m[2m:[0m slow statement: execution time exceeded alert threshold 
    [3msummary[0m[2m=[0m"SELECT * FROM duroxide.fetch_orchestration_item($1, …)" 
    [3mdb.statement[0m[2m=[0m"\n\nSELECT\n  *\nFROM\n  duroxide.fetch_orchestration_item($1, $2)\n" 
    [3mrows_affected[0m[2m=[0m0 
    [3mrows_returned[0m[2m=[0m1 
    [3melapsed[0m[2m=[0m1.02701925s 
    [3melapsed_secs[0m[2m=[0m1.02701925 
    [3mslow_threshold[0m[2m=[0m1s
```

### Full Container Startup + Deadlock Sequence

```
2025-12-07 21:59:00.451 UTC [55] LOG:  pg_durable: connecting to PostgreSQL at postgres://postgres@127.0.0.1:5432/postgres (schema: duroxide)

/usr/local/bin/docker-entrypoint.sh: running /docker-entrypoint-initdb.d/01-init-pg-durable.sh

2025-12-07 21:59:34.775 UTC [55] LOG:  pg_durable: duroxide background worker terminated cleanly

PostgreSQL init process complete; ready for start up.

2025-12-07 21:59:35.021 UTC [1] LOG:  database system is ready to accept connections

2025-12-07 21:59:35.024 UTC [72] LOG:  pg_durable: duroxide background worker starting...
2025-12-07 21:59:35.033 UTC [72] LOG:  pg_durable: initializing duroxide runtime with PostgreSQL store...
2025-12-07 21:59:35.036 UTC [72] LOG:  pg_durable: connecting to PostgreSQL at postgres://postgres@127.0.0.1:5432/postgres (schema: duroxide)
2025-12-07 21:59:35.259 UTC [72] LOG:  pg_durable: PostgreSQL store created in schema 'duroxide'
2025-12-07 21:59:35.301 UTC [72] LOG:  pg_durable: duroxide runtime started, processing durable functions...

-- Test execution begins here --

2025-12-07 21:59:56.770 UTC [76] ERROR:  deadlock detected
2025-12-07 21:59:56.770 UTC [76] DETAIL:  Process 76 waits for ShareLock on transaction 794; blocked by process 79.
	Process 79 waits for ShareLock on transaction 795; blocked by process 76.
	Process 76: SELECT * FROM duroxide.fetch_orchestration_item($1, $2)
	Process 79: SELECT * FROM duroxide.fetch_orchestration_item($1, $2)

-- Test times out waiting for completion --

2025-12-07 22:00:57.765 UTC [95] ERROR:  TEST FAILED: status = pending
2025-12-07 22:00:57.765 UTC [95] CONTEXT:  PL/pgSQL function inline_code_block line 22 at RAISE
```

## Technical Analysis

### The Problematic SQL Statement

The deadlock occurs in this SQL within `fetch_orchestration_item`:

```sql
INSERT INTO duroxide.instance_locks (instance_id, lock_token, locked_until, locked_at)
VALUES (v_instance_id, v_lock_token, v_locked_until, p_now_ms)
ON CONFLICT(instance_id) DO UPDATE
SET lock_token = EXCLUDED.lock_token,
    locked_until = EXCLUDED.locked_until,
    locked_at = EXCLUDED.locked_at
WHERE duroxide.instance_locks.locked_until <= p_now_ms
```

### Root Cause Hypothesis

1. **Concurrent INSERT with ON CONFLICT**: When two workers try to acquire locks for orchestration items related to the same instance (e.g., parallel branches of a JOIN), they both attempt to INSERT/UPDATE the `instance_locks` table.

2. **Index tuple insertion conflict**: The error mentions "while inserting index tuple (0,12) in relation 'instance_locks'", suggesting the unique index on `instance_id` is causing lock contention.

3. **ShareLock acquisition order**: PostgreSQL's ShareLock mechanism requires both transactions to wait for each other, creating a circular dependency.

### Potential Solutions

1. **Use advisory locks instead of table-based locks**:
   ```sql
   SELECT pg_advisory_xact_lock(hashtext(instance_id));
   ```

2. **Add explicit row-level locking with SKIP LOCKED**:
   ```sql
   SELECT * FROM duroxide.instance_locks 
   WHERE instance_id = v_instance_id 
   FOR UPDATE SKIP LOCKED;
   ```

3. **Serialize fetch_orchestration_item calls** at the application level for items belonging to the same orchestration instance.

4. **Use a different locking strategy** for parallel branches - perhaps acquire a parent lock before spawning child workers.

5. **Implement retry logic** in the Rust code when deadlock is detected (SQLSTATE '40P01').

## Observed Behavior

| Scenario | Outcome |
|----------|---------|
| Simple SQL (no parallelism) | ✅ Works |
| Sequence with `~>` | ✅ Works |
| Variables with `\|=>` | ✅ Works |
| Conditional with `durable.if()` | ✅ Works |
| Sleep with `durable.sleep()` | ✅ Works |
| Loop with `durable.loop()` | ✅ Works |
| Parallel JOIN (2 branches) | ❌ Deadlock (intermittent) |
| Parallel JOIN (3 branches) | ❌ Deadlock (intermittent) |
| JOIN followed by sequence | ❌ Deadlock (intermittent) |

## Intermittent Nature

The deadlock does not occur 100% of the time. It depends on the timing of when workers call `fetch_orchestration_item`. In some test runs, the parallel operations complete successfully; in others, the deadlock occurs.

This suggests a race condition window where:
- If workers acquire locks in a consistent order → success
- If workers acquire locks in conflicting order → deadlock

## Files Affected in pg_durable

Due to this issue, the following E2E tests are currently skipped:

- `tests/e2e/sql/04_parallel_join.sql`
- `tests/e2e/sql/12_scenario_parallel_counts.sql`
- `tests/e2e/sql/16_scenario_join3.sql`

## Contact

This issue was discovered while developing the `pg_durable` PostgreSQL extension, which uses `duroxide-pg` as its orchestration backend.

Repository: pg_durable
Date: December 7, 2025

