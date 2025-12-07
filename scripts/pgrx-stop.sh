#!/bin/bash
# pgrx-stop.sh - Stop the pgrx PostgreSQL server
#
# Usage: ./scripts/pgrx-stop.sh [pg_version]
#   pg_version: PostgreSQL version (default: 17)

set -e

PG_VERSION="${1:-17}"
PGRX_HOME="$HOME/.pgrx"
DATA_DIR="$PGRX_HOME/data-$PG_VERSION"

# Find pg_ctl
PG_CTL=$(ls $PGRX_HOME/$PG_VERSION.*/pgrx-install/bin/pg_ctl 2>/dev/null | head -1)

if [ -z "$PG_CTL" ]; then
    echo "Error: pg_ctl not found for PostgreSQL $PG_VERSION"
    exit 1
fi

if [ ! -d "$DATA_DIR" ]; then
    echo "Data directory $DATA_DIR does not exist"
    exit 1
fi

echo "Stopping PostgreSQL $PG_VERSION..."
"$PG_CTL" -D "$DATA_DIR" stop -m fast 2>/dev/null && echo "PostgreSQL stopped." || echo "PostgreSQL was not running."

