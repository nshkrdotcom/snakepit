#!/usr/bin/env bash
# Run the Python bridge test-suite with zero manual setup.
# Usage: ./test_python.sh [pytest args]

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}"
PY_DIR="${ROOT_DIR}/priv/python"
VENV_DIR="${ROOT_DIR}/.venv"

echo -e "${YELLOW}Running Python bridge tests...${NC}"

# Check if venv exists
if [ ! -d "${VENV_DIR}" ]; then
    echo -e "${RED}Error: Virtual environment not found at .venv${NC}"
    echo "Run: python3 -m venv .venv && .venv/bin/pip install -r priv/python/requirements.txt"
    exit 1
fi

# Ensure generated protobuf stubs exist; regenerate when missing
if [ ! -f "${PY_DIR}/snakepit_bridge_pb2.py" ] || [ ! -f "${PY_DIR}/snakepit_bridge_pb2_grpc.py" ]; then
    echo -e "${YELLOW}Generating gRPC protobuf stubs...${NC}"
    (cd "${PY_DIR}" && ./generate_grpc.sh>/dev/null)
fi

# Activate venv and run tests
source "${VENV_DIR}/bin/activate"

# Always add priv/python to PYTHONPATH so imports resolve without installation
if [ -n "${PYTHONPATH:-}" ]; then
    export PYTHONPATH="${PY_DIR}:${PYTHONPATH}"
else
    export PYTHONPATH="${PY_DIR}"
fi

# Check if pytest is installed inside the venv
if ! python -c "import pytest" >/dev/null 2>&1; then
    echo -e "${RED}Error: pytest not installed${NC}"
    echo "Run: ${VENV_DIR}/bin/pip install -r priv/python/requirements-dev.txt"
    exit 1
fi

# Run pytest with any additional args passed to script
echo -e "${GREEN}Running pytest from priv/python/tests/${NC}"
(cd "${PY_DIR}" && python -m pytest tests/ -v "$@")

exit_code=$?

if [ $exit_code -eq 0 ]; then
    echo -e "${GREEN}✓ All Python tests passed${NC}"
else
    echo -e "${RED}✗ Python tests failed${NC}"
fi

exit $exit_code
