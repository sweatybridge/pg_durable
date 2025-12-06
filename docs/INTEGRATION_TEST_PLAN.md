# pg_durable Integration Test Plan

## Overview

Integration tests verify end-to-end orchestration execution through the Duroxide runtime. Unlike unit tests that only verify node creation, these tests start orchestrations and wait for them to complete.

## Test Environment

### Prerequisites
- Background worker loaded via `shared_preload_libraries = 'pg_durable'`
- Duroxide runtime actively processing orchestrations
- PostgreSQL connection pool available

### Test Helper: Wait for Completion

All integration tests need a helper to poll for orchestration completion:

```rust
fn wait_for_completion(instance_id: &str, timeout_secs: u64) -> Result<String, String> {
    let start = std::time::Instant::now();
    let timeout = std::time::Duration::from_secs(timeout_secs);
    
    loop {
        // Query Duroxide for status
        let status = get_duroxide_status(instance_id);
        
        match status.as_str() {
            "Completed" => {
                return Ok(get_duroxide_output(instance_id));
            }
            "Failed" | "Canceled" => {
                return Err(format!("Orchestration {}: {}", status, get_duroxide_output(instance_id)));
            }
            _ => {
                if start.elapsed() > timeout {
                    return Err(format!("Timeout after {}s, status: {}", timeout_secs, status));
                }
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
        }
    }
}
```

---

## Test Categories

### 1. Simple SQL Execution

**Test: `test_e2e_simple_sql`**

| Step | Action | Expected |
|------|--------|----------|
| 1 | Create table: `CREATE TABLE test_e2e (id SERIAL, val TEXT)` | Table exists |
| 2 | Start orchestration: `durable.sql('INSERT INTO test_e2e (val) VALUES (''hello'') RETURNING id')` | Returns instance_id |
| 3 | Wait for completion (5s timeout) | Status = "Completed" |
| 4 | Verify result contains `{"rows":[{"id":1}],"row_count":1}` | Row inserted |
| 5 | Query table directly | Row exists with val = 'hello' |

**Validates**: Basic SQL execution through Duroxide activity

---

### 2. Sequence Execution (THEN/~>)

**Test: `test_e2e_sequence`**

| Step | Action | Expected |
|------|--------|----------|
| 1 | Create table: `test_seq (step INT, ts TIMESTAMPTZ DEFAULT now())` | Table exists |
| 2 | Start: `sql('INSERT INTO test_seq (step) VALUES (1)') ~> sql('INSERT INTO test_seq (step) VALUES (2)')` | Returns instance_id |
| 3 | Wait for completion | Status = "Completed" |
| 4 | Query: `SELECT step FROM test_seq ORDER BY ts` | Returns [1, 2] in order |

**Validates**: Sequential execution, THEN node processing

---

### 3. Variable Substitution

**Test: `test_e2e_variable_substitution`**

| Step | Action | Expected |
|------|--------|----------|
| 1 | Create table: `test_vars (source_id INT, copied_id INT)` | Table exists |
| 2 | Insert source row: `INSERT INTO test_vars (source_id) VALUES (42)` | Row exists |
| 3 | Start orchestration: |  |
| | `sql('SELECT source_id FROM test_vars LIMIT 1') \|=> 'src'` | |
| | `~> sql('INSERT INTO test_vars (copied_id) VALUES ($src) RETURNING copied_id')` | |
| 4 | Wait for completion | Status = "Completed" |
| 5 | Query table | copied_id = 42 |

**Validates**: Result naming with `|=>`, variable substitution with `$name`

---

### 4. Sleep Execution

**Test: `test_e2e_sleep`**

| Step | Action | Expected |
|------|--------|----------|
| 1 | Record start time | t0 |
| 2 | Start: `durable.sleep(2) ~> durable.sql('SELECT 1')` | Returns instance_id |
| 3 | Wait for completion (10s timeout) | Status = "Completed" |
| 4 | Record end time | t1 |
| 5 | Verify `t1 - t0 >= 2 seconds` | Sleep was honored |

**Validates**: Timer scheduling, sleep node execution

---

### 5. Conditional Branching (IF)

**Test: `test_e2e_if_true_branch`**

| Step | Action | Expected |
|------|--------|----------|
| 1 | Start: `durable.if(sql('SELECT true'), sql('SELECT ''yes'''), sql('SELECT ''no'''))` | Returns instance_id |
| 2 | Wait for completion | Status = "Completed" |
| 3 | Verify result contains `"yes"` | Then branch executed |

**Test: `test_e2e_if_false_branch`**

| Step | Action | Expected |
|------|--------|----------|
| 1 | Start: `durable.if(sql('SELECT false'), sql('SELECT ''yes'''), sql('SELECT ''no'''))` | Returns instance_id |
| 2 | Wait for completion | Status = "Completed" |
| 3 | Verify result contains `"no"` | Else branch executed |

**Test: `test_e2e_if_numeric_condition`**

| Step | Action | Expected |
|------|--------|----------|
| 1 | Start: `durable.if(sql('SELECT 0'), sql('SELECT ''yes'''), sql('SELECT ''no'''))` | Returns instance_id |
| 2 | Wait for completion | Status = "Completed" |
| 3 | Verify result contains `"no"` | 0 is falsy |

**Validates**: Condition evaluation, branch selection

---

### 6. Parallel Execution (JOIN)

**Test: `test_e2e_join_parallel`**

| Step | Action | Expected |
|------|--------|----------|
| 1 | Create table: `test_join (branch TEXT, ts TIMESTAMPTZ DEFAULT now())` | Table exists |
| 2 | Start: `durable.join(sql('INSERT ... branch=A'), sql('INSERT ... branch=B'))` | Returns instance_id |
| 3 | Wait for completion | Status = "Completed" |
| 4 | Query table | Both rows exist |
| 5 | Verify timestamps are close (< 1s apart) | Parallel execution |

**Test: `test_e2e_join3`**

| Step | Action | Expected |
|------|--------|----------|
| 1 | Start: `durable.join3(sql('SELECT 1'), sql('SELECT 2'), sql('SELECT 3'))` | Returns instance_id |
| 2 | Wait for completion | Status = "Completed" |
| 3 | Verify result is array with 3 elements | All branches completed |

**Validates**: Parallel sub-orchestration scheduling, join_all behavior

---

### 7. Loop with Continue-as-New

**Test: `test_e2e_loop_iterations`**

| Step | Action | Expected |
|------|--------|----------|
| 1 | Create table: `test_loop (iter INT, ts TIMESTAMPTZ DEFAULT now())` | Table exists |
| 2 | Start eternal orchestration: |  |
| | `durable.loop(sql('INSERT INTO test_loop (iter) SELECT COALESCE(MAX(iter),0)+1 FROM test_loop') ~> durable.sleep(1))` | Returns instance_id |
| 3 | Wait 5 seconds | Let loop run |
| 4 | Cancel orchestration: `durable.cancel(instance_id, 'test complete')` | Returns success |
| 5 | Query table: `SELECT COUNT(*) FROM test_loop` | At least 3 iterations |
| 6 | Verify instance status | Status = "Canceled" |

**Validates**: Loop execution, continue-as-new, cancellation

---

### 8. Cancellation

**Test: `test_e2e_cancel_running`**

| Step | Action | Expected |
|------|--------|----------|
| 1 | Start long sleep: `durable.sleep(300)` | Returns instance_id |
| 2 | Verify status is "Running" | Orchestration started |
| 3 | Cancel: `durable.cancel(instance_id, 'test cancel')` | Returns success |
| 4 | Verify status is "Canceled" | Cancellation worked |

**Validates**: Cancel API, status transitions

---

### 9. Monitoring Functions

**Test: `test_e2e_list_instances`**

| Step | Action | Expected |
|------|--------|----------|
| 1 | Start 3 orchestrations with labels | Instance IDs returned |
| 2 | Wait for all to complete | All completed |
| 3 | Call `durable.list_instances()` | Returns all 3 with correct labels |
| 4 | Call `durable.list_instances('Completed')` | Returns completed ones |

**Test: `test_e2e_metrics`**

| Step | Action | Expected |
|------|--------|----------|
| 1 | Call `durable.metrics()` | Returns row with counts |
| 2 | Start and complete an orchestration | |
| 3 | Call `durable.metrics()` again | total_instances increased |

**Test: `test_e2e_instance_info`**

| Step | Action | Expected |
|------|--------|----------|
| 1 | Start orchestration with label "test-info" | Returns instance_id |
| 2 | Wait for completion | |
| 3 | Call `durable.instance_info(instance_id)` | Returns correct orchestration_name, label, status |

**Test: `test_e2e_instance_nodes`**

| Step | Action | Expected |
|------|--------|----------|
| 1 | Start: `sql('SELECT 1') ~> sql('SELECT 2')` | Returns instance_id |
| 2 | Wait for completion | |
| 3 | Call `durable.instance_nodes(instance_id)` | Returns 3 nodes (2 SQL + 1 THEN) |

**Validates**: Duroxide Client API integration, monitoring queries

---

### 10. Error Handling

**Test: `test_e2e_sql_error`**

| Step | Action | Expected |
|------|--------|----------|
| 1 | Start: `durable.sql('SELECT * FROM nonexistent_table_xyz')` | Returns instance_id |
| 2 | Wait for completion | Status = "Failed" |
| 3 | Verify error message contains "does not exist" | Error captured |

**Test: `test_e2e_instance_status_sync`**

| Step | Action | Expected |
|------|--------|----------|
| 1 | Start and wait for completion | Status = "Completed" |
| 2 | Query `durable.instances` table | status = 'completed' |
| 3 | Query `durable.list_instances()` | Status matches |

**Validates**: Error propagation, status synchronization between PostgreSQL and Duroxide

---

## Test Summary

| Category | Tests | Priority |
|----------|-------|----------|
| Simple SQL | 1 | P0 - Critical |
| Sequence | 1 | P0 - Critical |
| Variables | 1 | P0 - Critical |
| Sleep | 1 | P1 - Important |
| Conditional | 3 | P1 - Important |
| Parallel | 2 | P1 - Important |
| Loop | 1 | P1 - Important |
| Cancellation | 1 | P1 - Important |
| Monitoring | 4 | P2 - Nice to have |
| Error Handling | 2 | P2 - Nice to have |
| **Total** | **17** | |

## Implementation Notes

1. **Timeout Handling**: All tests should have reasonable timeouts (5-30s) to prevent hanging
2. **Cleanup**: Each test should clean up its test tables in a `finally` block
3. **Isolation**: Use unique table names per test to avoid conflicts
4. **Polling Interval**: 100ms is reasonable for status polling
5. **Duroxide Access**: Tests need to call the Duroxide Client API to get true status (not just PostgreSQL table)

## Implementation Status

All integration tests have been implemented in `src/lib.rs`. However, they are marked `#[ignore]` because:

1. **pgrx test framework limitation**: `postgresql_conf_options()` doesn't actually apply `shared_preload_libraries`
2. **Background worker never starts**: Without shared_preload_libraries, the Duroxide runtime never initializes
3. **Orchestrations never process**: Tests timeout waiting for work that never gets picked up

**Root cause verified**: The generated `postgresql.conf` shows `#shared_preload_libraries = ''` (commented out) even when `postgresql_conf_options()` returns `vec!["shared_preload_libraries = 'pg_durable'"]`.

## Running Integration Tests

### Option 1: Manual Testing via psql

```bash
# Start PostgreSQL with the extension
cargo pgrx run pg17

# In another terminal, connect to PostgreSQL
psql -p 28817 -d postgres

# Run test SQL manually (see examples in USER_GUIDE.md)
```

### Option 2: Docker Environment

```bash
# Build and start Docker container
docker compose up -d

# Connect and run tests
docker compose exec postgres psql -U postgres -d postgres
```

### Option 3: Run Ignored Tests (requires running PostgreSQL)

```bash
# First start PostgreSQL with extension loaded
cargo pgrx run pg17

# In another terminal, run ignored tests
cargo pgrx test pg17 -- --ignored
```

## Test Summary

| Category | Unit Tests | Integration Tests |
|----------|-----------|-------------------|
| DSL Node Creation | 8 ✅ | - |
| Instance Management | 4 ✅ | - |
| SQL Operators | 2 ✅ | - |
| Edge Cases | 2 ✅ | - |
| E2E: Simple SQL | - | 1 ⏸️ |
| E2E: Sequence | - | 1 ⏸️ |
| E2E: Variables | - | 1 ⏸️ |
| E2E: Sleep | - | 1 ⏸️ |
| E2E: Conditional | - | 3 ⏸️ |
| E2E: Parallel | - | 2 ⏸️ |
| E2E: Cancel | - | 1 ⏸️ |
| E2E: Monitoring | - | 4 ⏸️ |
| E2E: Error Handling | - | 2 ⏸️ |
| **Total** | **16 ✅** | **16 ⏸️** |

Legend: ✅ = Passes in `cargo pgrx test`, ⏸️ = Ignored (requires manual testing)

