# pg_durable - Current Status

## Overview

**pg_durable** is a PostgreSQL extension that provides SQL-native durable workflows using the [duroxide](https://github.com/duroxide/duroxide) framework. It allows you to define and execute durable, fault-tolerant workflows directly from SQL.

## What Has Been Done

### 1. Extension Skeleton ✅
- Created pgrx-based PostgreSQL extension (`pg_durable_ext`)
- Configured for PostgreSQL 17 with pgrx 0.16.1
- Added `durable` schema for all extension functions

### 2. DSL Functions ✅
Implemented SQL functions for building workflow graphs:
- `durable.sql(query)` - Create a SQL execution node
- `durable.seq(a, b)` - Sequence two nodes (run a, then b)
- `durable.as(name, node)` - Name a result for later reference
- `durable.start(node)` - Start a workflow instance
- `durable.status(instance_id)` - Check workflow status
- `durable.run(node)` - Synchronously run a workflow
- `durable.result(instance_id)` - Get workflow result

### 3. SQL Operators ✅
Created custom PostgreSQL operators for ergonomic workflow chaining:
- `~>` operator for sequencing: `a ~> b` means "run a, then run b"
- `|=>` operator for naming: `'name' |=> node` means "name this result"

Example:
```sql
SELECT durable.start(
  durable.sql('SELECT 1') ~> durable.sql('SELECT 2')
);
```

### 4. Workflow Storage Tables ✅
Created PostgreSQL tables for workflow persistence:
- `durable.nodes` - Stores workflow node definitions (SQL steps, sequences, etc.)
- `durable.instances` - Stores workflow instance state and status

### 5. SPI-Based Execution Engine ✅
Implemented a basic execution engine using PostgreSQL's SPI (Server Programming Interface):
- `execute_node()` - Recursively executes workflow node trees
- `execute_sql_node()` - Executes individual SQL queries
- `execute_workflow()` - Manages workflow instance lifecycle

### 6. Duroxide Integration ✅
Integrated the duroxide durable task framework:
- Added `duroxide` and `tokio` dependencies
- Created background worker that runs duroxide runtime
- Implemented shared SQLite store for IPC between main thread and background worker

### 7. Background Worker Architecture ✅
The duroxide runtime now runs in a PostgreSQL background worker:
- **Background Worker** (`pg_durable_duroxide`):
  - Starts when PostgreSQL starts (via `shared_preload_libraries`)
  - Runs duroxide runtime with SQLite store at `~/pg_durable_duroxide.db`
  - Registers activities: `Greet`, `ExecuteSQL`
  - Registers orchestrations: `HelloWorld`
  - Processes orchestrations asynchronously

- **Client Functions** (called from SQL):
  - `start_duroxide_orchestration()` - Start an orchestration via shared store
  - `wait_duroxide_orchestration()` - Wait for orchestration completion
  - `get_duroxide_status()` - Check orchestration status

### 8. SQL Interface for Duroxide ✅
Exposed duroxide functionality through SQL:
- `durable.hello(name)` - Start HelloWorld orchestration, wait for result
- `durable.duroxide_test()` - Test duroxide integration
- `durable.orchestration_status(id)` - Check orchestration status

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     PostgreSQL Server                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─────────────────────┐     ┌──────────────────────────┐   │
│  │  SQL Functions       │     │  Background Worker       │   │
│  │  - durable.hello()   │     │  (pg_durable_duroxide)   │   │
│  │  - durable.sql()     │     │                          │   │
│  │  - durable.seq()     │     │  ┌────────────────────┐  │   │
│  │  - durable.start()   │     │  │ Duroxide Runtime   │  │   │
│  └──────────┬──────────┘     │  │ - Greet Activity   │  │   │
│             │                 │  │ - HelloWorld Orch  │  │   │
│             │                 │  └─────────┬──────────┘  │   │
│             │                 │            │              │   │
│             └────────────┐    └────────────┼──────────────┘   │
│                          │                 │                  │
│                          ▼                 ▼                  │
│                    ┌─────────────────────────┐               │
│                    │   SQLite Store          │               │
│                    │   ~/pg_durable_         │               │
│                    │   duroxide.db           │               │
│                    └─────────────────────────┘               │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Configuration

The extension requires `pg_durable_ext` in `shared_preload_libraries`:
```
# postgresql.conf
shared_preload_libraries = 'pg_durable_ext'
```

## Testing

```sql
-- Test duroxide integration
SELECT durable.duroxide_test();
-- Returns: SUCCESS: Hello, duroxide!

-- Run a hello world orchestration
SELECT durable.hello('World');
-- Returns: Hello, World!

-- Check orchestration status
SELECT durable.orchestration_status('some-uuid');
-- Returns: Completed { output: "Hello, World!" }
```

---

## Next Steps

### 1. Wire DSL to Duroxide
Connect the existing DSL (`durable.sql()`, `durable.seq()`, etc.) to duroxide orchestrations:
- Implement `ExecuteWorkflow` orchestration that reads from `durable.nodes` table
- Make `durable.start()` create a duroxide orchestration instead of polling
- Have the duroxide worker execute the workflow graph using SPI

### 2. Add ExecuteSQL Activity
Implement a duroxide activity that can execute SQL:
- The activity needs access to PostgreSQL (via a connection pool or SPI)
- Consider using `duroxide-pg` provider instead of SQLite for direct PostgreSQL integration
- Handle result serialization between duroxide and PostgreSQL

### 3. Improve Error Handling
- Add proper error types and propagation
- Handle SQLite locking contention (currently shows warnings)
- Add retry logic for transient failures

### 4. Add Workflow Features
- **Parallelism**: Add `durable.par(a, b)` for parallel execution
- **Conditionals**: Add `durable.if(cond, then, else)` for branching
- **Loops**: Add `durable.while(cond, body)` for iteration
- **Timeouts**: Add `durable.timeout(node, duration)` for deadlines
- **Retries**: Add `durable.retry(node, attempts)` for resilience

### 5. Switch to duroxide-pg Provider
Replace SQLite with PostgreSQL-native duroxide provider:
- Use `duroxide-pg` for persistence in PostgreSQL tables
- Eliminates SQLite file dependency
- Better transaction semantics with PostgreSQL

### 6. Add Observability
- Workflow execution history
- Step-level timing and status
- Integration with PostgreSQL logging

### 7. Production Hardening
- Connection pooling for SPI execution
- Resource limits and quotas
- Authentication and authorization
- Metrics and monitoring

### 8. Documentation
- API reference for all functions
- Tutorial with examples
- Architecture deep-dive
- Deployment guide

---

## Files

- `pg_durable_ext/src/lib.rs` - Main extension code
- `pg_durable_ext/Cargo.toml` - Rust dependencies
- `pg_durable_ext/pg_durable_ext.control` - Extension control file
- `~/pg_durable_duroxide.db` - Duroxide SQLite store (runtime)

## Dependencies

- **pgrx**: 0.16.1 - PostgreSQL extension framework
- **duroxide**: 0.1.0 - Durable task orchestration
- **tokio**: 1.x - Async runtime
- **serde/serde_json**: JSON serialization
- **uuid**: UUID generation
