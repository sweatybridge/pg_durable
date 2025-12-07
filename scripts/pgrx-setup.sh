#!/bin/bash
# pgrx-setup.sh - Setup script for pg_durable development with pgrx
#
# Usage: ./scripts/pgrx-setup.sh [--clean] [pg_version]
#   --clean:    Remove existing data directory and start fresh
#   pg_version: PostgreSQL version (default: 17)
#
# Examples:
#   ./scripts/pgrx-setup.sh           # Start/restart with existing data
#   ./scripts/pgrx-setup.sh --clean   # Fresh start, wipes all data
#   ./scripts/pgrx-setup.sh --clean 16  # Fresh start with PG 16
#
# This script:
#   1. Kills any existing PostgreSQL on the pgrx port
#   2. (--clean only) Removes old data directory for a clean start
#   3. Builds and installs the extension
#   4. Initializes PostgreSQL with shared_preload_libraries configured
#   5. Creates the SQLite store file
#   6. Starts PostgreSQL with the background worker

set -e

# Parse arguments
CLEAN=false
PG_VERSION="17"

while [[ $# -gt 0 ]]; do
    case $1 in
        --clean)
            CLEAN=true
            shift
            ;;
        *)
            PG_VERSION="$1"
            shift
            ;;
    esac
done

PGRX_HOME="$HOME/.pgrx"
DATA_DIR="$PGRX_HOME/data-$PG_VERSION"
PG_PORT="28817"

echo "=== pg_durable pgrx setup (PostgreSQL $PG_VERSION) ==="
if [ "$CLEAN" = true ]; then
    echo "Mode: CLEAN (fresh start, all data will be wiped)"
else
    echo "Mode: PRESERVE (keeping existing data if present)"
fi

# Find the actual paths (handles version like 17.7)
PG_CTL=$(ls $PGRX_HOME/$PG_VERSION.*/pgrx-install/bin/pg_ctl 2>/dev/null | head -1)
PSQL=$(ls $PGRX_HOME/$PG_VERSION.*/pgrx-install/bin/psql 2>/dev/null | head -1)
PG_CONFIG=$(ls $PGRX_HOME/$PG_VERSION.*/pgrx-install/bin/pg_config 2>/dev/null | head -1)
INITDB=$(ls $PGRX_HOME/$PG_VERSION.*/pgrx-install/bin/initdb 2>/dev/null | head -1)

if [ -z "$PG_CTL" ] || [ -z "$PG_CONFIG" ]; then
    echo "Error: PostgreSQL binaries not found. Run 'cargo pgrx init' first."
    exit 1
fi

echo "Using pg_config: $PG_CONFIG"

# Step 1: Stop any running PostgreSQL
echo ""
echo "Step 1: Stopping any existing PostgreSQL..."

# Try graceful stop first using pg_ctl if data dir exists
if [ -d "$DATA_DIR" ]; then
    "$PG_CTL" -D "$DATA_DIR" stop -m fast 2>/dev/null || true
    sleep 2
fi

# Kill any postgres processes that might be using our port
PIDS=$(lsof -ti :$PG_PORT 2>/dev/null || true)
if [ -n "$PIDS" ]; then
    echo "  Killing processes: $PIDS"
    echo "$PIDS" | xargs kill -9 2>/dev/null || true
    sleep 2
fi

# Check if port is actually listening (not just stale connections)
if lsof -i :$PG_PORT -sTCP:LISTEN >/dev/null 2>&1; then
    echo "Error: Could not free port $PG_PORT (still listening)"
    exit 1
fi
echo "  Port $PG_PORT is available."

# Step 2: Handle data directory
echo ""
if [ "$CLEAN" = true ]; then
    echo "Step 2: Cleaning data directory..."
    rm -rf "$DATA_DIR"
    rm -f "$PGRX_HOME/.s.PGSQL.$PG_PORT"*
    NEEDS_INIT=true
elif [ ! -d "$DATA_DIR" ]; then
    echo "Step 2: Data directory doesn't exist, will initialize..."
    NEEDS_INIT=true
else
    echo "Step 2: Preserving existing data directory..."
    NEEDS_INIT=false
fi

# Step 3: Build and install extension
echo ""
echo "Step 3: Building and installing extension..."
cargo pgrx install --pg-config "$PG_CONFIG"

# Step 4: Initialize data directory (if needed)
if [ "$NEEDS_INIT" = true ]; then
    echo ""
    echo "Step 4: Initializing PostgreSQL data directory..."
    "$INITDB" -D "$DATA_DIR" >/dev/null
    
    # Step 5: Configure shared_preload_libraries
    echo ""
    echo "Step 5: Configuring shared_preload_libraries..."
    echo "shared_preload_libraries = 'pg_durable'" >> "$DATA_DIR/postgresql.conf"
    
    # Step 6: Create SQLite store file
    echo ""
    echo "Step 6: Creating SQLite store file..."
    touch "$DATA_DIR/pg_durable_duroxide.db"
    chmod 600 "$DATA_DIR/pg_durable_duroxide.db"
else
    echo ""
    echo "Step 4-6: Skipping init (data directory exists)..."
    
    # Ensure shared_preload_libraries is configured
    if ! grep -q "shared_preload_libraries.*pg_durable" "$DATA_DIR/postgresql.conf" 2>/dev/null; then
        echo "  Adding shared_preload_libraries..."
        echo "shared_preload_libraries = 'pg_durable'" >> "$DATA_DIR/postgresql.conf"
    fi
    
    # Ensure SQLite store file exists
    if [ ! -f "$DATA_DIR/pg_durable_duroxide.db" ]; then
        echo "  Creating SQLite store file..."
        touch "$DATA_DIR/pg_durable_duroxide.db"
        chmod 600 "$DATA_DIR/pg_durable_duroxide.db"
    fi
fi

# Step 7: Start PostgreSQL
echo ""
echo "Step 7: Starting PostgreSQL..."
LOG_FILE="$PGRX_HOME/$PG_VERSION.log"
"$PG_CTL" -D "$DATA_DIR" -l "$LOG_FILE" \
    -o "-p $PG_PORT -c unix_socket_directories=$PGRX_HOME" \
    start

sleep 2

# Step 8: Create database and extension
echo ""
echo "Step 8: Creating database and extension..."
"$PSQL" -h "$PGRX_HOME" -p $PG_PORT -d postgres -c "CREATE DATABASE pg_durable;" 2>/dev/null || true
"$PSQL" -h "$PGRX_HOME" -p $PG_PORT -d postgres -c "CREATE EXTENSION IF NOT EXISTS pg_durable;"

# Verify
echo ""
echo "=== Setup Complete ==="
echo ""
"$PSQL" -h "$PGRX_HOME" -p $PG_PORT -d postgres -c "SELECT durable.version();"

echo ""
echo "PostgreSQL is running on port $PG_PORT"
echo ""
echo "Connect with:"
echo "  psql -h localhost -p $PG_PORT -d postgres"
echo ""
echo "Or use pgrx:"
echo "  cargo pgrx run pg$PG_VERSION"
echo ""
echo "View logs:"
echo "  tail -f $LOG_FILE"
echo ""
echo "Stop PostgreSQL:"
echo "  $PG_CTL -D $DATA_DIR stop"

