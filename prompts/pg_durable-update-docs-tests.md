# Update Documentation and Tests After Code Changes

## Objective
Ensure all documentation is accurate, complete, and helpful after code changes. Also propose additional E2E tests to cover the changes.

## Step 1: Scan Changes and Propose Tests

**First, analyze what changed:**
1. Run `git diff --cached` to see staged changes
2. Run `git diff` to see unstaged changes
3. Identify new features, bug fixes, or behavior changes

**For each significant change, propose tests:**
- New DSL functions → E2E tests in `tests/e2e/sql/`
- New operators → E2E tests with both operator and function variants
- Bug fixes → Regression tests
- API changes → Example updates in USER_GUIDE.md

**Ask the user:**
- Present a list of changes found
- Propose specific tests for each change
- Ask which tests to implement before proceeding

## Step 2: Documentation Hierarchy

### 2.1 User-Facing Guide (Priority: High, MUST scan)

**`USER_GUIDE.md`** - Main user documentation

**Review criteria:**
- Examples compile and use current SQL syntax
- All DSL functions are documented in the reference table
- All operators are documented with examples
- Code patterns match working E2E tests
- Instructions are prescriptive and actionable
- Examples are succinct but complete

### 2.2 Other Documentation (Priority: Medium)

- **`README.md`** - Project overview, quick examples
- **`docs/TESTING.md`** - Testing setup and commands
- **`docs/pg_durable_mvp.md`** - MVP specification

**Review criteria:**
- README has accurate quick start example
- Testing docs reflect current script locations
- All commands actually work

### 2.3 Code Documentation (Priority: Medium)

Review doc comments in public-facing modules:
- **`src/dsl.rs`** - DSL functions (`df.sql()`, `df.if()`, etc.)
- **`src/monitoring.rs`** - Monitoring functions
- **`src/explain.rs`** - Explain function
- **`src/types.rs`** - Core types

## Step 3: E2E Test Updates

### Test File Naming Convention
```
tests/e2e/sql/
├── 00_setup_playground.sql      # Setup test data
├── 01_simple_sql.sql            # Basic tests
├── 02_sequence.sql              # Sequence operator
├── ...
├── 11_scenario_etl.sql          # Scenario tests
├── 12_scenario_*.sql            # More scenarios
└── 17_race.sql                  # Feature tests
```

### Test File Structure
```sql
-- Test: [Feature Name]
-- Tests [what variants/features]
-- Expected: [expected behavior]

-- Setup
DROP TABLE IF EXISTS test_table;
CREATE TABLE test_table (...);

-- Test variant A
SELECT df.start(...);

-- Test variant B (if applicable)
SELECT df.start(...);

-- Wait for completion
SELECT pg_sleep(N);

-- Verify
DO $$
DECLARE
    status TEXT;
BEGIN
    -- Check status
    SELECT s INTO status FROM df.status(inst_id) s;
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: status = %', status;
    END IF;
    
    -- Additional assertions...
    
    RAISE NOTICE 'TEST PASSED: feature_name';
END $$;

-- Cleanup
DROP TABLE test_table;
SELECT 'TEST PASSED' AS result;
```

### Running Tests
```bash
# Run all E2E tests
./scripts/test-e2e-local.sh

# Run specific test
./scripts/test-e2e-local.sh 04_parallel

# Keep server running for debugging
./scripts/test-e2e-local.sh --keep

# Connect to debug
psql -h localhost -p 28817 -d postgres
```

## Step 4: Validation Checklist

### Documentation
- [ ] USER_GUIDE.md examples use current syntax (`df.` schema)
- [ ] All operators documented (`~>`, `|=>`, `&`, `|`, `?>`, `!>`, `@>`)
- [ ] All functions documented in reference table
- [ ] Quick Reference Card is accurate
- [ ] No references to old `durable.` schema

### Tests
- [ ] New features have E2E tests
- [ ] Tests cover both operator and function variants where applicable
- [ ] Tests clean up after themselves
- [ ] Tests have clear PASSED/FAILED output
- [ ] `./scripts/test-e2e-local.sh` passes all tests

### Code
- [ ] `cargo build --features pg17` succeeds
- [ ] `cargo clippy --features pg17` has no warnings
- [ ] `cargo pgrx test --features pg17` passes

## Common Issues to Watch For

1. **Outdated schema name** - Using `durable.` instead of `df.`
2. **Missing operator documentation** - New operators not in reference
3. **Broken examples** - SQL that doesn't match current API
4. **Incomplete test variants** - Missing operator or function variant
5. **Hardcoded instance IDs** - Tests that don't generate unique IDs
6. **Missing cleanup** - Tests that leave tables/functions behind

## Quality Standards

### Good Documentation
- **Prescriptive**: "Do X, then Y" not "You could do X"
- **Complete**: Shows full context, not just fragments
- **Accurate**: Actually compiles and works
- **Helpful**: Explains why, not just how

### Good Examples
```sql
-- ✅ GOOD: Complete, explains purpose
-- Process orders in parallel with timeout protection
SELECT df.start(
    'SELECT id FROM orders WHERE status = ''pending'' LIMIT 1' |=> 'order_id'
    ~> (
        'UPDATE orders SET status = ''processing'' WHERE id = $order_id'
        | df.sleep(30)  -- 30 second timeout
    ),
    'process-order'
);
```

### Poor Examples
```sql
-- ❌ BAD: Incomplete, no context
df.start('SELECT 1')
```

## Ask Before Making Large Changes

If documentation updates require:
- Creating new guide documents
- Removing entire sections
- Restructuring organization
- Adding new example files
- Implementing more than 3 new tests

Then summarize the proposed changes and ask for confirmation before proceeding.

## Final Validation

After completing documentation and test updates:

1. Run `./scripts/test-e2e-local.sh` - All tests should pass
2. Verify USER_GUIDE.md examples by copy-pasting into psql
3. Check that new features are documented
4. Verify no broken internal links

