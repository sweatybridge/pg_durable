#!/bin/bash
# pg-reset.sh - Reset local PostgreSQL data (wipe everything)
#
# Usage: ./scripts/pg-reset.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_DIR="$HOME/.pgrx/data-17"

cd "$PROJECT_DIR"

echo -e "\033[0;33mStopping PostgreSQL if running...\033[0m"
cargo pgrx stop pg17 2>/dev/null || true

echo -e "\033[0;33mRemoving data directory: $DATA_DIR\033[0m"
rm -rf "$DATA_DIR"

echo -e "\033[0;33mClearing log file...\033[0m"
rm -f "$HOME/.pgrx/17.log"

echo -e "\033[0;32mPostgreSQL data and logs wiped.\033[0m"
echo ""
echo "Run ./scripts/pg-start.sh to start fresh."

