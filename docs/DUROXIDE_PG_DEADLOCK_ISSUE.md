# Duroxide-PG Deadlock Issue in Parallel Orchestrations

## Summary

We're using `duroxide-pg` as the storage backend for an orchestration system. When executing orchestrations with parallel branches (e.g., joining multiple sub-orchestrations), a deadlock occurs in the `fetch_orchestration_item` function when multiple workers attempt to acquire locks on the `instance_locks` table simultaneously.

## Context: How We Use Duroxide-PG

We have a PostgreSQL extension that embeds the Duroxide runtime as a background worker. Users define orchestration graphs (sequences, conditionals, parallel joins, loops) which get executed by the Duroxide runtime using `duroxide-pg` for persistence.

**Our setup:**
- Duroxide runtime runs as a PostgreSQL background worker
- We use `PostgresProvider::new_with_schema()` to create the store in a `duroxide` schema
- Orchestrations are started via `Worker::start_orchestration()`
- The runtime processes orchestration items via the standard Duroxide polling loop

**Orchestration types we support:**
- Sequential execution (A → B → C)
- Conditional branching (if/else)
- Parallel join (execute A and B concurrently, wait for both)
- Loops with continue-as-new

The deadlock **only** occurs with parallel operations (joins).

## Environment

- **PostgreSQL**: 17.7 (Debian 17.7-3.pgdg12+1)
- **duroxide-pg**: Latest version from crates.io
- **Platform**: linux/amd64 (Docker container)
- **Schema**: `duroxide` (custom schema passed to `new_with_schema`)

## Problem Description

When an orchestration has parallel branches that need to execute concurrently:

1. The Duroxide runtime schedules multiple sub-orchestrations (or activities) to run in parallel
2. Multiple async tasks call `fetch_orchestration_item()` to acquire work
3. Both workers attempt to INSERT/UPDATE the `instance_locks` table
4. PostgreSQL detects a deadlock and aborts one transaction
5. After deadlock resolution, the orchestration instance gets stuck in a non-terminal state

The orchestration never completes - it remains in "Pending" or "Running" state indefinitely.

## Reproduction Scenario

### Orchestration Structure (Pseudo-code)

```
Orchestration: ParallelJoinTest
├── JOIN
│   ├── Branch A: Execute SQL "INSERT INTO log VALUES ('A')"
│   └── Branch B: Execute SQL "INSERT INTO log VALUES ('B')"
└── (wait for both branches to complete)
```

### What Happens

1. Main orchestration starts
2. JOIN node schedules Branch A and Branch B as parallel work items
3. Worker Task 1 calls `fetch_orchestration_item()` for Branch A
4. Worker Task 2 calls `fetch_orchestration_item()` for Branch B
5. **DEADLOCK** - both tasks wait for each other's transaction

### Three-Way Join (Even More Likely to Deadlock)

```
Orchestration: ThreeWayJoinTest
├── JOIN
│   ├── Branch A: Activity 1
│   ├── Branch B: Activity 2
│   └── Branch C: Activity 3
└── (wait for all three)
```

### Join Followed by Continuation

```
Orchestration: JoinThenContinue
├── JOIN
│   ├── Branch A: Count users
│   └── Branch B: Count orders
├── THEN
│   └── Log "counts complete"
```

## Logs

### Deadlock Detection

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

### Slow Query Warnings (from sqlx, post-deadlock)

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

### Full Timeline

```
-- Duroxide runtime initialization --
2025-12-07 21:59:35.021 UTC [1] LOG:  database system is ready to accept connections
2025-12-07 21:59:35.024 UTC [72] LOG:  pg_durable: duroxide background worker starting...
2025-12-07 21:59:35.033 UTC [72] LOG:  pg_durable: initializing duroxide runtime with PostgreSQL store...
2025-12-07 21:59:35.036 UTC [72] LOG:  pg_durable: connecting to PostgreSQL at postgres://postgres@127.0.0.1:5432/postgres (schema: duroxide)
2025-12-07 21:59:35.259 UTC [72] LOG:  PostgreSQL store created in schema 'duroxide'
2025-12-07 21:59:35.301 UTC [72] LOG:  duroxide runtime started, processing...

-- User starts an orchestration with parallel JOIN --
-- (orchestration_id: 780d0395, has 2 parallel branches) --

-- ~21 seconds later, deadlock occurs --
2025-12-07 21:59:56.770 UTC [76] ERROR:  deadlock detected
2025-12-07 21:59:56.770 UTC [76] DETAIL:  Process 76 waits for ShareLock on transaction 794; blocked by process 79.
	Process 79 waits for ShareLock on transaction 795; blocked by process 76.
	Process 76: SELECT * FROM duroxide.fetch_orchestration_item($1, $2)
	Process 79: SELECT * FROM duroxide.fetch_orchestration_item($1, $2)

-- Orchestration stays stuck, never completes --
-- Status check 60 seconds later still shows "pending" --
```

## Technical Analysis

### The Problematic SQL Statement

The deadlock occurs at line 28 of `fetch_orchestration_item`, in this SQL:

```sql
INSERT INTO duroxide.instance_locks (instance_id, lock_token, locked_until, locked_at)
VALUES (v_instance_id, v_lock_token, v_locked_until, p_now_ms)
ON CONFLICT(instance_id) DO UPDATE
SET lock_token = EXCLUDED.lock_token,
    locked_until = EXCLUDED.locked_until,
    locked_at = EXCLUDED.locked_at
WHERE duroxide.instance_locks.locked_until <= p_now_ms
```

### Root Cause Analysis

1. **Concurrent `INSERT ... ON CONFLICT`**: When two workers try to fetch orchestration items (potentially for different instances, or different items of the same parent orchestration), they both execute the INSERT with ON CONFLICT.

2. **Index tuple insertion deadlock**: The error states "while inserting index tuple (0,12) in relation 'instance_locks'". The unique index on `instance_id` is causing lock contention.

3. **ShareLock circular wait**: 
   - Transaction 794 (Process 76) holds a lock and waits for Transaction 795
   - Transaction 795 (Process 79) holds a lock and waits for Transaction 794
   - Classic deadlock scenario

4. **Post-deadlock state corruption**: After PostgreSQL aborts one transaction to break the deadlock, something goes wrong with the orchestration state. The aborted transaction's work item doesn't get properly re-queued or the orchestration state becomes inconsistent.

### Why This Only Affects Parallel Operations

- **Sequential orchestrations**: Only one item is fetched at a time → no concurrent `fetch_orchestration_item` calls → no deadlock
- **Parallel orchestrations (JOIN)**: Multiple items need to be fetched concurrently → multiple `fetch_orchestration_item` calls → potential deadlock

## Potential Solutions

### 1. Use Advisory Locks Instead of Table Locks

```sql
-- Before attempting to acquire instance lock
SELECT pg_advisory_xact_lock(hashtext(v_instance_id));
-- Then do the INSERT ... ON CONFLICT
```

This serializes access at a higher level, preventing the deadlock.

### 2. Use SELECT FOR UPDATE with SKIP LOCKED

```sql
-- First, try to lock the existing row
SELECT * FROM duroxide.instance_locks 
WHERE instance_id = v_instance_id 
FOR UPDATE SKIP LOCKED;

-- If row exists and we got the lock, update it
-- If row doesn't exist, insert it
-- If row exists but SKIP LOCKED skipped it, return nothing (item already being processed)
```

### 3. Implement Retry Logic in Rust

When `fetch_orchestration_item` fails with SQLSTATE `40P01` (deadlock_detected), retry the operation:

```rust
loop {
    match fetch_orchestration_item(&pool, now_ms, lock_duration_ms).await {
        Ok(item) => return Ok(item),
        Err(e) if e.is_deadlock() => {
            // Random backoff and retry
            tokio::time::sleep(Duration::from_millis(rand::random::<u64>() % 100)).await;
            continue;
        }
        Err(e) => return Err(e),
    }
}
```

### 4. Serialize Lock Acquisition

Instead of having each worker independently call `fetch_orchestration_item`, have a single dispatcher that acquires items and hands them to workers:

```rust
// Single dispatcher acquires all pending items
let items = fetch_orchestration_items_batch(&pool, count).await?;
// Distribute to workers (no concurrent lock acquisition)
for item in items {
    worker_pool.submit(item);
}
```

### 5. Change INSERT Order / Use UPSERT with Deterministic Ordering

If multiple rows are being inserted, ensure they're always inserted in the same order (e.g., sorted by instance_id) to avoid circular wait conditions.

## Observed Behavior Summary

| Orchestration Type | Result |
|-------------------|--------|
| Single activity | ✅ Works |
| Sequence (A → B → C) | ✅ Works |
| Conditional (if/else) | ✅ Works |
| Timer/Sleep | ✅ Works |
| Loop with continue-as-new | ✅ Works |
| Parallel JOIN (2 branches) | ❌ Deadlock (intermittent) |
| Parallel JOIN (3 branches) | ❌ Deadlock (intermittent) |
| JOIN then continue | ❌ Deadlock (intermittent) |

## Intermittent Nature

The deadlock doesn't occur 100% of the time. It depends on the exact timing of when workers call `fetch_orchestration_item`:

- **If workers acquire locks in a consistent order** → success
- **If workers happen to acquire locks in conflicting order** → deadlock

In our testing, roughly 50-70% of parallel JOIN operations result in a deadlock.

## Additional Context

We're happy to provide more information or test patches. This is blocking our ability to use Duroxide for any workflows that require parallel execution.

**Our Rust initialization code:**

```rust
use duroxide_pg::PostgresProvider;

let store = PostgresProvider::new_with_schema(&pg_conn_str, Some("duroxide"))
    .await
    .expect("Failed to create PostgreSQL store");

let worker = Worker::new(store, worker_config);
worker.run().await;
```

**Our orchestration scheduling:**

```rust
// When we need parallel execution, we schedule sub-orchestrations
let branch_a = ctx.schedule_sub_orchestration("BranchA", input_a);
let branch_b = ctx.schedule_sub_orchestration("BranchB", input_b);

// Wait for both (this is where the deadlock occurs during item fetching)
let (result_a, result_b) = futures::join!(branch_a, branch_b);
```

---

**Reporter**: pg_durable development team  
**Date**: December 7, 2025  
**duroxide-pg version**: Latest from crates.io
