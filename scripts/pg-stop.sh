#!/bin/bash
# pg-stop.sh - Stop PostgreSQL servers
#
# Usage: ./scripts/pg-stop.sh [options]
#
# Options:
#   --local      Stop local pgrx PostgreSQL (default)
#   --docker     Stop Docker container
#   --all        Stop both local and Docker

set -e

STOP_LOCAL=false
STOP_DOCKER=false

# Parse arguments
if [ $# -eq 0 ]; then
    STOP_LOCAL=true
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        --local)
            STOP_LOCAL=true
            shift
            ;;
        --docker)
            STOP_DOCKER=true
            shift
            ;;
        --all)
            STOP_LOCAL=true
            STOP_DOCKER=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: ./scripts/pg-stop.sh [--local|--docker|--all]"
            exit 1
            ;;
    esac
done

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Stop local pgrx PostgreSQL
if [ "$STOP_LOCAL" = true ]; then
    PGRX_HOME="$HOME/.pgrx"
    PG_VERSION="17"
    PG_CTL=$(ls $PGRX_HOME/$PG_VERSION.*/pgrx-install/bin/pg_ctl 2>/dev/null | head -1)
    DATA_DIR="$PGRX_HOME/data-$PG_VERSION"
    
    if [ -n "$PG_CTL" ] && [ -d "$DATA_DIR" ]; then
        if "$PG_CTL" status -D "$DATA_DIR" &>/dev/null; then
            echo -e "${YELLOW}Stopping local PostgreSQL...${NC}"
            "$PG_CTL" -D "$DATA_DIR" stop -m fast 2>/dev/null || true
            echo -e "${GREEN}Local PostgreSQL stopped${NC}"
        else
            echo "Local PostgreSQL is not running"
        fi
    else
        echo "Local pgrx PostgreSQL not found"
    fi
fi

# Stop Docker container
if [ "$STOP_DOCKER" = true ]; then
    CONTAINER_NAME="pg_durable_e2e"
    
    if docker ps -q -f name="$CONTAINER_NAME" | grep -q .; then
        echo -e "${YELLOW}Stopping Docker container...${NC}"
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
        echo -e "${GREEN}Docker container stopped${NC}"
    else
        echo "Docker container is not running"
    fi
fi

