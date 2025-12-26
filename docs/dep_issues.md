# Dependency Issues & Blockers

**Purpose:** Track duroxide-pg-opt issues/limitations that require workarounds in pg_durable.

**Last Updated:** 2024-12-22

**GitHub Query:** [All pg_durable issues in duroxide-pg-opt](https://github.com/Azure/duroxide-pg-opt/issues?q=is%3Aissue+label%3Apg_durable)

---

## How to Check for Fixes

1. **Check duroxide-pg-opt releases:**
   ```bash
   gh release list --repo Azure/duroxide-pg-opt --limit 10
   ```

2. **Check specific issue status:**
   ```bash
   gh issue view <ISSUE_NUMBER> --repo Azure/duroxide-pg-opt
   ```

3. **Check current duroxide version in use:**
   ```bash
   grep 'duroxide = ' Cargo.toml
   ```

4. **After duroxide update, search for STOPGAP markers:**
   ```bash
   grep -rn "STOPGAP\|BLOCKED on duroxide\|TODO.*duroxide fix" --include="*.rs" .
   ```

---

## Active Blockers

### 1. Schema Versioning for duroxide-pg Provider

| Field | Value |
|-------|-------|
| **Issue** | [Azure/duroxide-pg-opt#6](https://github.com/Azure/duroxide-pg-opt/issues/6) |
| **Also filed** | [affandar/duroxide-pg#1](https://github.com/affandar/duroxide-pg/issues/1) (FYI only) |
| **Status** | 🔴 Open |
| **Fixed In** | TBD |
| **Workaround Location** | `scripts/test-e2e-local.sh` |

**Problem:**
When upgrading `duroxide` or `duroxide-pg-opt` versions, the PostgreSQL schema in the `duroxide` schema may change (new columns, changed function signatures, etc.). This causes runtime errors:
- `function duroxide.XXX does not exist` (function signature changed)
- `column index out of bounds` (table columns changed)
- `cached plan must not change result type` (prepared statement cache invalidated)

There is no built-in way to detect schema version mismatches or handle migrations.

**Current Workaround:**
- Test scripts drop the entire `duroxide` schema before restart
- Requires full PostgreSQL restart to clear sqlx's prepared statement cache
- For production: manual `DROP SCHEMA duroxide CASCADE` + restart

**Desired Solution:**
1. Store schema version in `duroxide.metadata` table
2. On provider startup, check if schema version matches library version
3. Options:
   - Auto-migrate (for compatible changes)
   - Fail fast with clear error message (for breaking changes)
   - Provide migration scripts between versions

**When Fixed - Cleanup Steps:**
1. Update duroxide/duroxide-pg-opt dependency in `Cargo.toml`
2. Remove manual schema drop logic from test scripts
3. Implement proper upgrade documentation
4. Update this document

**Files to Update:**
- [ ] `scripts/test-e2e-local.sh` (remove `DROP SCHEMA duroxide CASCADE`)
- [ ] Documentation (add upgrade guide)

---

## Resolved Blockers

_None yet. Move items here when fixed._

<!--
Template for resolved blocker:

### [RESOLVED] Issue Title

| Field | Value |
|-------|-------|
| **Issue** | [GitHub #XX](https://github.com/anthropics/duroxide/issues/XX) |
| **Status** | ✅ Resolved |
| **Fixed In** | v0.1.X |
| **Cleanup PR** | [#YY](link) |

**Resolution Date:** YYYY-MM-DD
-->

---

## Checklist After Duroxide Update

When updating the duroxide dependency, run through this checklist:

1. [ ] Check if any issues in "Active Blockers" are fixed in the new version
2. [ ] Run `grep -rn "STOPGAP\|BLOCKED on duroxide" --include="*.rs" .` to find workarounds
3. [ ] For each fixed issue:
   - [ ] Remove the workaround code
   - [ ] Run the affected tests to confirm fix
   - [ ] Move the blocker to "Resolved Blockers" section
4. [ ] Run full test suite: `./scripts/test-unit.sh`
5. [ ] Run E2E tests with `--clean`: `./scripts/test-e2e-local.sh --clean`
6. [ ] Update this document with new status

---

## Version Compatibility Matrix

| pg_durable | duroxide | duroxide-pg-opt | Notes |
|------------|----------|-----------------|-------|
| 0.1.0 | 0.1.6 | 0.1.6 | Current |
