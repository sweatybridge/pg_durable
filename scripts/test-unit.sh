#!/bin/bash
# test-unit.sh - Run pgrx unit tests
#
# Usage: ./scripts/test-unit.sh [test_filter]
#
# Examples:
#   ./scripts/test-unit.sh              # Run all unit tests
#   ./scripts/test-unit.sh simple       # Run tests matching "simple"

set -e

cd "$(dirname "$0")/.."

TEST_FILTER="${1:-}"

echo "================================================"
echo "pg_durable Unit Tests (pgrx)"
echo "================================================"
echo ""

if [ -n "$TEST_FILTER" ]; then
    echo "Filter: $TEST_FILTER"
    cargo pgrx test pg17 -- "$TEST_FILTER"
else
    cargo pgrx test pg17
fi

