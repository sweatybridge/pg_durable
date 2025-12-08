# Duroxide-PG Deadlock Issue in Parallel Orchestrations

## Summary

We're using `duroxide-pg` as the storage backend for an orchestration system. When executing orchestrations with parallel branches (e.g., joining multiple sub-orchestrations), a deadlock occurs in the `fetch_orchestration_item` function when multiple workers attempt to acquire locks on the `instance_locks` table simultaneously.

**🔴 Critical Finding:** The deadlock itself is handled by PostgreSQL (aborts one transaction after 1 second). However, **the sub-orchestration completion notification is lost** when this happens. Sub-orchestrations complete successfully, but the parent orchestration never gets notified and waits forever.

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

4. **Lost completion notifications**: After PostgreSQL aborts one transaction to break the deadlock, the **sub-orchestration completion signal is lost**. The sub-orchestration is marked complete in its own record, but the parent orchestration never receives notification.

## 🔴 CRITICAL FINDING: Lost Completion Notifications

**PostgreSQL's deadlock_timeout is 1 second.** After detecting a deadlock, PostgreSQL aborts one transaction. However, this doesn't fix the problem - the orchestration remains stuck forever.

### Evidence from Database State

After a deadlock occurs, querying the `duroxide.executions` table shows:

```
    instance_id    | execution_id |  status   
-------------------+--------------+-----------
 7e98f125          |            1 | Running     <-- Parent stuck!
 7e98f125::sub::10 |            1 | Completed   <-- Child completed
 7e98f125::sub::11 |            1 | Completed   <-- Child completed
 8cb6f497          |            1 | Running     <-- Parent stuck!
 8cb6f497::sub::10 |            1 | Completed   <-- Child completed
 8cb6f497::sub::11 |            1 | Completed   <-- Child completed
```

**Both sub-orchestrations completed successfully, but the parent orchestrations are stuck in "Running" forever!**

The queues are empty - no pending work:
```sql
SELECT * FROM duroxide.orchestrator_queue;  -- 0 rows
SELECT * FROM duroxide.worker_queue;         -- 0 rows
SELECT * FROM duroxide.instance_locks;       -- 0 rows
```

### What's Happening

1. Sub-orchestration A completes its work
2. Sub-orchestration A tries to notify parent (signal completion)
3. **DEADLOCK** occurs during this notification
4. PostgreSQL aborts the notification transaction
5. Sub-orchestration A's status is updated to "Completed" (separate transaction)
6. **But the parent never receives the completion signal**
7. Parent waits forever for children that already finished

### The Real Bug

The deadlock itself isn't the main problem - PostgreSQL handles it correctly by aborting one transaction after 1 second. **The real bug is that the completion notification is lost and never retried.**

When a sub-orchestration completes, duroxide-pg needs to:
1. Mark the sub-orchestration as complete ✅ (this works)
2. Signal the parent orchestration to wake up ❌ (this gets lost on deadlock)

If step 2 fails due to deadlock, it should be retried. Currently it appears to be silently dropped.

### Why This Only Affects Parallel Operations

- **Sequential orchestrations**: Only one item is fetched at a time → no concurrent `fetch_orchestration_item` calls → no deadlock
- **Parallel orchestrations (JOIN)**: Multiple items need to be fetched concurrently → multiple `fetch_orchestration_item` calls → potential deadlock

## Potential Solutions

### Priority 1: Fix Lost Completion Notifications (Critical)

The most important fix is ensuring completion notifications are never lost:

```rust
// When sub-orchestration completes, retry notification until successful
async fn signal_parent_completion(parent_id: &str, child_id: &str) -> Result<()> {
    loop {
        match notify_parent(&pool, parent_id, child_id).await {
            Ok(_) => return Ok(()),
            Err(e) if e.is_deadlock() => {
                // Deadlock - retry with backoff
                tokio::time::sleep(Duration::from_millis(rand::random::<u64>() % 100)).await;
                continue;
            }
            Err(e) => return Err(e),
        }
    }
}
```

Or use a transactional outbox pattern:
1. Write completion + notification to an outbox table in same transaction
2. Background process reads outbox and delivers notifications
3. Notifications are guaranteed to be delivered eventually

### Priority 2: Prevent the Deadlock

#### Option A: Use Advisory Locks

```sql
-- Before attempting to acquire instance lock
SELECT pg_advisory_xact_lock(hashtext(v_instance_id));
-- Then do the INSERT ... ON CONFLICT
```

This serializes access at a higher level, preventing the deadlock.

#### Option B: Use SELECT FOR UPDATE with SKIP LOCKED

```sql
-- First, try to lock the existing row
SELECT * FROM duroxide.instance_locks 
WHERE instance_id = v_instance_id 
FOR UPDATE SKIP LOCKED;

-- If row exists and we got the lock, update it
-- If row doesn't exist, insert it
-- If row exists but SKIP LOCKED skipped it, return nothing (item already being processed)
```

#### Option C: Retry on Deadlock in fetch_orchestration_item

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

#### Option D: Serialize Lock Acquisition

Single dispatcher acquires all pending items and distributes to workers:

```rust
let items = fetch_orchestration_items_batch(&pool, count).await?;
for item in items {
    worker_pool.submit(item);
}
```

#### Option E: Deterministic Lock Ordering

If multiple rows are being inserted, ensure they're always inserted in the same order (e.g., sorted by instance_id) to avoid circular wait conditions.

### Priority 3: Add Orphan Detection

As a safety net, periodically scan for "orphaned" parent orchestrations:

```sql
-- Find parents stuck waiting for already-completed children
SELECT DISTINCT p.instance_id as stuck_parent
FROM duroxide.executions p
JOIN duroxide.executions c ON c.instance_id LIKE p.instance_id || '::sub::%'
WHERE p.status = 'Running'
AND NOT EXISTS (
    SELECT 1 FROM duroxide.executions c2 
    WHERE c2.instance_id LIKE p.instance_id || '::sub::%'
    AND c2.status != 'Completed'
);
```

Then re-queue these parents for processing.

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
use duroxide::{
    OrchestrationContext, OrchestrationRegistry,
    runtime::{self, registry::ActivityRegistry},
};
use duroxide_pg::PostgresProvider;
use std::sync::Arc;

// Create the PostgreSQL store
let store = PostgresProvider::new_with_schema(&pg_conn_str, Some("duroxide"))
    .await
    .expect("Failed to create PostgreSQL store");

// Register activities
let activities = ActivityRegistry::builder()
    .register("ExecuteSQL", |ctx: ActivityContext, query: String| async move {
        // ... execute SQL ...
    })
    .build();

// Register orchestrations
let orchestrations = OrchestrationRegistry::builder()
    .register("ExecuteWorkflow", |ctx: OrchestrationContext, input: String| async move {
        // ... workflow logic ...
    })
    .register("ExecuteSubtree", |ctx: OrchestrationContext, input: String| async move {
        // Used for parallel branches - each branch runs as a sub-orchestration
    })
    .build();

// Start the runtime
let runtime = runtime::Runtime::start_with_store(
    Arc::new(store),
    Arc::new(activities),
    orchestrations
).await;
```

**How we handle JOIN (parallel execution):**

```rust
// In our "join" node handler within the orchestration:
"join" => {
    let left_id = node.left_node.as_ref().ok_or("Missing left branch")?;
    let right_id = node.right_node.as_ref().ok_or("Missing right branch")?;
    
    ctx.trace_info("Executing JOIN branches in parallel");
    
    // Serialize graph and results state for sub-orchestrations
    let graph_json = serde_json::to_string(&graph)?;
    let results_json = serde_json::to_string(&results)?;
    
    let left_input = serde_json::json!({
        "graph": graph_json,
        "node_id": left_id,
        "results": results_json
    }).to_string();
    
    let right_input = serde_json::json!({
        "graph": graph_json,
        "node_id": right_id,
        "results": results_json
    }).to_string();
    
    // Schedule sub-orchestrations for each branch
    // THIS IS WHERE THE DEADLOCK OCCURS - when Duroxide tries to fetch
    // orchestration items for both sub-orchestrations concurrently
    let mut join_handles = Vec::new();
    for input in vec![left_input, right_input] {
        let fut = ctx.schedule_sub_orchestration("ExecuteSubtree", input)
            .into_sub_orchestration();
        join_handles.push(fut);
    }
    
    // Wait for all branches to complete
    let results_vec = futures::future::join_all(join_handles).await;
    
    // Process results...
}
```

**The deadlock scenario:**

1. Main orchestration reaches JOIN node
2. `ctx.schedule_sub_orchestration()` is called twice, scheduling two sub-orchestrations
3. Duroxide runtime has multiple async tasks that poll for work
4. Task A calls `fetch_orchestration_item()` to pick up the first sub-orchestration
5. Task B calls `fetch_orchestration_item()` to pick up the second sub-orchestration  
6. Both tasks try to INSERT/UPDATE the `instance_locks` table simultaneously
7. **DEADLOCK** - both tasks wait for each other's transaction

**Key observation:** The deadlock is in `duroxide-pg`'s `fetch_orchestration_item()` function, not in our application code. The issue is how `duroxide-pg` handles concurrent lock acquisition when multiple orchestration items become available at the same time.

---

**Reporter**: pg_durable development team  
**Date**: December 8, 2025  
**duroxide-pg version**: Latest from crates.io  
**PostgreSQL deadlock_timeout**: 1s (default)
