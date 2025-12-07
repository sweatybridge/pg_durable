# E2E Testing Guide for pg_durable

This guide explains how to set up and run end-to-end tests for pg_durable.

## Prerequisites

1. **Docker** - Required to run the test container
   ```bash
   # Verify Docker is installed and running
   docker --version
   docker ps
   ```

2. **Rust toolchain** - For building the extension
   ```bash
   # Install via rustup if needed
   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
   ```

## Quick Start

From the project root:

```bash
# Run all E2E tests
./run-e2e-tests.sh
```

That's it! The script will:
1. Build the Docker image with pg_durable
2. Start a container with PostgreSQL + pg_durable
3. Wait for the background worker to be ready
4. Run all SQL test files
5. Report results
6. Clean up the container

## What Gets Tested

| Test | Description |
|------|-------------|
| `01_simple_sql` | Basic SQL execution |
| `02_sequence` | Sequential steps with `~>` |
| `03_variables` | Variable substitution with `\|=>` and `$var` |
| `04_parallel_join` | Parallel execution with `durable.join()` |
| `05_conditional_true` | `durable.if()` true branch |
| `06_conditional_false` | `durable.if()` false branch |
| `07_sleep` | Timer/sleep functionality |
| `08_loop_cancel` | Loop execution and cancellation |
| `09_monitoring` | Monitoring functions (list_instances, status, result) |
| `10_explain` | `durable.explain()` dry-run and live instance |

## Test Structure

```
pg_durable/
├── run-e2e-tests.sh          # Main test runner (in root for easy access)
└── tests/
    └── e2e/
        ├── run.sh            # Same script (canonical location)
        └── sql/
            ├── 01_simple_sql.sql
            ├── 02_sequence.sql
            └── ...           # More test files
```

## Writing New Tests

Create a new `.sql` file in `tests/e2e/sql/`:

```sql
-- Test: Description of what this tests
-- Expected: What should happen

\set ON_ERROR_STOP on

-- Setup (optional)
DROP TABLE IF EXISTS test_mytable;
CREATE TABLE test_mytable (...);

-- Start the durable function
SELECT durable.start(...) AS instance_id \gset

-- Wait for completion
DO $$
DECLARE
    status TEXT;
    attempts INT := 0;
BEGIN
    LOOP
        SELECT s INTO status FROM durable.status(:'instance_id') s;
        EXIT WHEN status IN ('Completed', 'Failed', 'Canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF status != 'Completed' THEN
        RAISE EXCEPTION 'TEST FAILED: expected Completed, got %', status;
    END IF;
END $$;

-- Verify results
DO $$
BEGIN
    -- Your assertions here
    IF (some condition fails) THEN
        RAISE EXCEPTION 'TEST FAILED: reason';
    END IF;
END $$;

-- Cleanup
DROP TABLE test_mytable;

-- Report success
SELECT 'TEST PASSED: my_test_name' AS result;
```

## Debugging Failed Tests

### View container logs

```bash
# Keep container running after failure (edit run-e2e-tests.sh)
# Comment out: trap cleanup EXIT

# Then after failure:
docker logs pg_durable_e2e_<pid>
```

### Run single test manually

```bash
# Start container
docker run -d --name pg-debug --platform linux/amd64 \
  -e POSTGRES_PASSWORD=postgres pg_durable:e2e-test

# Wait for startup
sleep 15

# Run one test with full output
docker exec -i pg-debug psql -U postgres < tests/e2e/sql/04_parallel_join.sql

# Check logs
docker logs pg-debug 2>&1 | tail -50

# Interactive debugging
docker exec -it pg-debug psql -U postgres

# Cleanup
docker stop pg-debug && docker rm pg-debug
```

### Connect to running test container

If you need to inspect a running container during tests:

```bash
# In another terminal while tests are running
docker exec -it pg_durable_e2e_<pid> psql -U postgres
```

## CI Integration

Add to your CI pipeline:

```yaml
# GitHub Actions example
jobs:
  e2e-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run E2E tests
        run: ./run-e2e-tests.sh
```

## Makefile Targets

```bash
make test        # Run all tests (unit + E2E)
make test-e2e    # Run only E2E tests
make test-unit   # Run only pgrx unit tests
```

## Troubleshooting

### Docker not running
```
Error: Cannot connect to the Docker daemon
```
→ Start Docker Desktop or the Docker daemon

### Port conflicts
```
Error: port is already allocated
```
→ Stop other PostgreSQL containers: `docker ps` and `docker stop <container>`

### Image build fails
```
Error: cargo build failed
```
→ Check Rust is installed: `rustc --version`
→ Try `cargo build` locally first to see errors

### Tests timeout
```
TEST FAILED: status = pending
```
→ Background worker may not be starting. Check logs:
```bash
docker logs <container> 2>&1 | grep -i "duroxide\|error\|fatal"
```

### Platform mismatch (Apple Silicon)
```
WARNING: The requested image's platform (linux/amd64) does not match
```
→ This is expected on M1/M2 Macs. The tests use `--platform linux/amd64` for compatibility with the pre-built extension.

