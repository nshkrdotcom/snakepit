#!/usr/bin/env bash
# Run the Python bridge test-suite with zero manual setup.
# Usage: ./test_python.sh [pytest args]

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}"
PY_DIR="${ROOT_DIR}/priv/python"
VENV_DIR="${ROOT_DIR}/.venv"
REQ_FILE="${PY_DIR}/requirements.txt"
REQ_HASH_FILE="${VENV_DIR}/.snakepit_requirements.hash"
PYTHON_BIN="${PYTHON_BIN:-python3}"

echo -e "${YELLOW}Running Python bridge tests...${NC}"

# Ensure python interpreter exists
if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo -e "${RED}Error: ${PYTHON_BIN} not found on PATH${NC}"
    exit 1
fi

# Create venv automatically if missing
if [ ! -d "${VENV_DIR}" ]; then
    echo -e "${YELLOW}Creating Python virtualenv at ${VENV_DIR}...${NC}"
    "${PYTHON_BIN}" -m venv "${VENV_DIR}"
    VENV_CREATED=1
else
    VENV_CREATED=0
fi

ACTIVATE_SCRIPT="${VENV_DIR}/bin/activate"
if [ ! -f "${ACTIVATE_SCRIPT}" ]; then
    echo -e "${RED}Error: unable to locate ${ACTIVATE_SCRIPT}${NC}"
    exit 1
fi

source "${ACTIVATE_SCRIPT}"

# Ensure requirements are installed whenever they change
CURRENT_HASH="$(sha256sum "${REQ_FILE}" | awk '{print $1}')"
NEED_INSTALL=0

if [ "${VENV_CREATED}" -eq 1 ] || [ ! -f "${REQ_HASH_FILE}" ]; then
    NEED_INSTALL=1
else
    STORED_HASH="$(cat "${REQ_HASH_FILE}")"
    if [ "${CURRENT_HASH}" != "${STORED_HASH}" ]; then
        NEED_INSTALL=1
    fi
fi

if [ "${NEED_INSTALL}" -eq 1 ]; then
    echo -e "${YELLOW}Installing Python requirements...${NC}"
    "${VENV_DIR}/bin/python" -m pip install --upgrade pip setuptools wheel >/dev/null
    "${VENV_DIR}/bin/pip" install -r "${REQ_FILE}"
    echo "${CURRENT_HASH}" > "${REQ_HASH_FILE}"
fi

# Ensure generated protobuf stubs exist; regenerate when missing
if [ ! -f "${PY_DIR}/snakepit_bridge_pb2.py" ] || [ ! -f "${PY_DIR}/snakepit_bridge_pb2_grpc.py" ]; then
    echo -e "${YELLOW}Generating gRPC protobuf stubs...${NC}"
    (cd "${PY_DIR}" && ./generate_grpc.sh >/dev/null)
fi

# Always add priv/python to PYTHONPATH so imports resolve without installation
if [ -n "${PYTHONPATH:-}" ]; then
    export PYTHONPATH="${PY_DIR}:${PYTHONPATH}"
else
    export PYTHONPATH="${PY_DIR}"
fi

# Disable noisy OTEL exporters during local test runs unless explicitly enabled.
export OTEL_TRACES_EXPORTER="${OTEL_TRACES_EXPORTER:-none}"
export SNAKEPIT_OTEL_CONSOLE="${SNAKEPIT_OTEL_CONSOLE:-false}"

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
