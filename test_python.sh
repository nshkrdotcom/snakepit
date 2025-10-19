#!/bin/bash
# Run Python tests from project root
# Usage: ./test_python.sh [pytest args]

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Running Python tests...${NC}"

# Check if venv exists
if [ ! -d ".venv" ]; then
    echo -e "${RED}Error: Virtual environment not found at .venv${NC}"
    echo "Run: python3 -m venv .venv && .venv/bin/pip install -r priv/python/requirements.txt"
    exit 1
fi

# Activate venv and run tests
cd priv/python
source ../../.venv/bin/activate

# Ensure bridge package is importable without installation
if [ -n "${PYTHONPATH:-}" ]; then
    export PYTHONPATH="$(pwd):$PYTHONPATH"
else
    export PYTHONPATH="$(pwd)"
fi

# Check if pytest is installed
if ! python -c "import pytest" 2>/dev/null; then
    echo -e "${RED}Error: pytest not installed${NC}"
    echo "Run: .venv/bin/pip install pytest"
    exit 1
fi

# Run pytest with any additional args passed to script
echo -e "${GREEN}Running pytest in priv/python/tests/${NC}"
python -m pytest tests/ -v "$@"

exit_code=$?

if [ $exit_code -eq 0 ]; then
    echo -e "${GREEN}✓ All Python tests passed${NC}"
else
    echo -e "${RED}✗ Python tests failed${NC}"
fi

exit $exit_code
