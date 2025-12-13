# Proposal: Parameterized Queries (Status: Not Implemented)

## Overview
This proposal outlines the design and implementation for mitigating SQL injection risks in `pg_durable` by implementing parameterized queries. This feature was implemented but reverted for future consideration.

## Problem
The `df.sql` function currently accepts a raw SQL string. This string is executed directly by the `execute_sql` activity, potentially allowing SQL injection if user input is concatenated into the string.

## Proposed Design

### DSL Change
Update `dsl::sql` to accept an optional arguments parameter (JSONB).

```rust
pub fn sql(query: &str, args: Option<pgrx::JsonB>) -> String {
    // ...
}
```

This function constructs a JSON configuration object:
```json
{
  "query": "SELECT * FROM users WHERE id = $1",
  "args": [123]
}
```

### Activity Change
Update `activities::execute_sql` to parse this JSON configuration. If "args" are present, use `sqlx`'s binding mechanism to bind parameters safely.

```rust
// Logic to bind serde_json::Value types to sqlx query
match arg {
    serde_json::Value::String(s) => query = query.bind(s),
    serde_json::Value::Number(n) => ...
    // ...
}
```

### Usability
Users would call it as:
```sql
SELECT df.sql('SELECT * FROM table WHERE id = $1', jsonb_build_array(1));
```

## Backward Compatibility
Existing calls using raw strings should continue to work by treating the input as a query with no arguments.

## Verification
- Unit tests in `dsl.rs` to verify JSON generation.
- E2E tests verifying parameter binding for various types.

## Reason for Revert
Reverted to simplify the current scope and defer this enhancement.
