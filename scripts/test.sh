#!/bin/bash
# Unified test runner for pg_durable
# Runs both pgrx unit tests and Docker-based E2E tests

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --unit       Run only pgrx unit tests"
    echo "  --e2e        Run only E2E tests (Docker)"
    echo "  --all        Run all tests (default)"
    echo "  --help       Show this help"
    echo ""
    echo "Examples:"
    echo "  $0              # Run all tests"
    echo "  $0 --unit       # Run only unit tests"
    echo "  $0 --e2e        # Run only E2E tests"
}

RUN_UNIT=false
RUN_E2E=false

# Parse arguments
if [ $# -eq 0 ]; then
    RUN_UNIT=true
    RUN_E2E=true
else
    for arg in "$@"; do
        case $arg in
            --unit)
                RUN_UNIT=true
                ;;
            --e2e)
                RUN_E2E=true
                ;;
            --all)
                RUN_UNIT=true
                RUN_E2E=true
                ;;
            --help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $arg"
                usage
                exit 1
                ;;
        esac
    done
fi

cd "$PROJECT_DIR"

UNIT_RESULT=0
E2E_RESULT=0

# Run unit tests
if [ "$RUN_UNIT" = true ]; then
    echo ""
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}Running pgrx Unit Tests${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo ""
    
    if cargo pgrx test pg17; then
        echo -e "${GREEN}Unit tests passed!${NC}"
    else
        UNIT_RESULT=1
        echo -e "${RED}Unit tests failed!${NC}"
    fi
fi

# Run E2E tests
if [ "$RUN_E2E" = true ]; then
    echo ""
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}Running E2E Tests (Docker)${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo ""
    
    if "$PROJECT_DIR/tests/e2e/run.sh"; then
        echo -e "${GREEN}E2E tests passed!${NC}"
    else
        E2E_RESULT=1
        echo -e "${RED}E2E tests failed!${NC}"
    fi
fi

# Summary
echo ""
echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}Test Summary${NC}"
echo -e "${BLUE}================================================${NC}"

if [ "$RUN_UNIT" = true ]; then
    if [ $UNIT_RESULT -eq 0 ]; then
        echo -e "  Unit Tests:  ${GREEN}PASS${NC}"
    else
        echo -e "  Unit Tests:  ${RED}FAIL${NC}"
    fi
fi

if [ "$RUN_E2E" = true ]; then
    if [ $E2E_RESULT -eq 0 ]; then
        echo -e "  E2E Tests:   ${GREEN}PASS${NC}"
    else
        echo -e "  E2E Tests:   ${RED}FAIL${NC}"
    fi
fi

echo ""

# Exit with failure if any tests failed
exit $((UNIT_RESULT + E2E_RESULT))

