#!/bin/bash
# Verify Python 3.13 environment is working correctly

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "========================================================================"
echo "Python 3.13 Environment Verification"
echo "========================================================================"
echo ""

# Check venv exists
if [ ! -d ".venv-py313" ]; then
    echo -e "${RED}✗${NC} .venv-py313 not found. Run scripts/setup_test_pythons.sh first."
    exit 1
fi

echo "1. Python version:"
.venv-py313/bin/python --version
echo ""

echo "2. Import test (grpc, numpy, protobuf):"
.venv-py313/bin/python -c "
import grpc
import numpy
from google import protobuf
print('  grpcio:', grpc.__version__)
print('  numpy:', numpy.__version__)
print('  protobuf:', protobuf.__version__)
"
echo ""

echo "3. GIL support:"
.venv-py313/bin/python -c "
import sys
has_gil = hasattr(sys, '_is_gil_enabled')
print('  Has _is_gil_enabled:', has_gil)
if has_gil:
    print('  GIL enabled:', sys._is_gil_enabled())
    print('  Note: To test free-threading, set PYTHON_GIL=0')
"
echo ""

echo "4. Threading test:"
.venv-py313/bin/python -c "
import threading
success = False
def test_thread():
    global success
    success = True

thread = threading.Thread(target=test_thread)
thread.start()
thread.join()
print('  Threading works:', success)
"
echo ""

echo "5. grpc_server_threaded.py:"
if .venv-py313/bin/python priv/python/grpc_server_threaded.py --help &> /dev/null; then
    echo -e "  ${GREEN}✓${NC} Can run grpc_server_threaded.py"
else
    echo -e "  ${RED}✗${NC} Cannot run grpc_server_threaded.py"
    exit 1
fi

echo ""
echo -e "${GREEN}✓${NC} All checks passed!"
echo ""
