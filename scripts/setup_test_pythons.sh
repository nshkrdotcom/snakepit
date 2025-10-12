#!/bin/bash
# Setup Python environments for Snakepit testing
# Creates isolated venvs for Python 3.12 (GIL) and 3.13 (free-threading)

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "========================================================================"
echo "Snakepit Python Test Environment Setup"
echo "========================================================================"
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check for requirements file
REQUIREMENTS="priv/python/requirements.txt"
if [ ! -f "$REQUIREMENTS" ]; then
    echo "Creating basic requirements.txt..."
    cat > "$REQUIREMENTS" << EOF
grpcio>=1.60.0
grpcio-tools>=1.60.0
protobuf>=4.25.0
numpy>=1.24.0
EOF
fi

# ============================================================================
# Python 3.12 Environment (GIL present)
# ============================================================================

echo "Python 3.12 Environment (GIL):"
echo "------------------------------------------------------------------------"

if [ -d ".venv" ]; then
    echo -e "${GREEN}✓${NC} .venv exists"
    .venv/bin/python --version
else
    # Try to find python3.12
    if command -v python3.12 &> /dev/null; then
        echo "Creating .venv with Python 3.12..."
        python3.12 -m venv .venv
        .venv/bin/pip install --upgrade pip > /dev/null
        .venv/bin/pip install -r "$REQUIREMENTS"
        echo -e "${GREEN}✓${NC} Created .venv"
        .venv/bin/python --version
    elif command -v python3 &> /dev/null; then
        # Use default python3 (might be 3.12)
        PY_VERSION=$(python3 --version | grep -oE '[0-9]+\.[0-9]+')
        echo "Using default python3 (version $PY_VERSION)..."
        python3 -m venv .venv
        .venv/bin/pip install --upgrade pip > /dev/null
        .venv/bin/pip install -r "$REQUIREMENTS"
        echo -e "${GREEN}✓${NC} Created .venv"
        .venv/bin/python --version
    else
        echo -e "${RED}✗${NC} Python 3 not found. Please install Python 3.8+"
        exit 1
    fi
fi

# ============================================================================
# Python 3.13 Environment (free-threading capable)
# ============================================================================

echo ""
echo "Python 3.13 Environment (Free-Threading):"
echo "------------------------------------------------------------------------"

if [ -d ".venv-py313" ]; then
    echo -e "${GREEN}✓${NC} .venv-py313 exists"
    .venv-py313/bin/python --version

    # Check GIL status
    GIL_STATUS=$(.venv-py313/bin/python -c "import sys; print('disabled' if hasattr(sys, '_is_gil_enabled') and callable(sys._is_gil_enabled) and not sys._is_gil_enabled() else 'enabled')" 2>/dev/null || echo "unknown")
    echo "   GIL status: $GIL_STATUS"
else
    # Check for uv (preferred) or python3.13
    if command -v uv &> /dev/null; then
        echo "Creating .venv-py313 with uv (Python 3.13)..."
        uv venv .venv-py313 --python 3.13
        uv pip install --python .venv-py313/bin/python -r "$REQUIREMENTS"
        echo -e "${GREEN}✓${NC} Created .venv-py313"
        .venv-py313/bin/python --version

        # Check GIL status
        GIL_STATUS=$(.venv-py313/bin/python -c "import sys; print('disabled' if hasattr(sys, '_is_gil_enabled') and callable(sys._is_gil_enabled) and not sys._is_gil_enabled() else 'enabled')" 2>/dev/null || echo "unknown")
        echo "   GIL status: $GIL_STATUS"

        if [ "$GIL_STATUS" = "enabled" ]; then
            echo -e "${YELLOW}   Note: GIL is still enabled. To test free-threading:${NC}"
            echo "   - Use Python 3.13 built with --disable-gil"
            echo "   - Or set PYTHON_GIL=0 environment variable"
        fi
    elif command -v python3.13 &> /dev/null; then
        echo "Creating .venv-py313 with Python 3.13..."
        python3.13 -m venv .venv-py313
        .venv-py313/bin/pip install --upgrade pip > /dev/null
        .venv-py313/bin/pip install -r "$REQUIREMENTS"
        echo -e "${GREEN}✓${NC} Created .venv-py313"
        .venv-py313/bin/python --version

        # Check GIL status
        GIL_STATUS=$(.venv-py313/bin/python -c "import sys; print('disabled' if hasattr(sys, '_is_gil_enabled') and callable(sys._is_gil_enabled) and not sys._is_gil_enabled() else 'enabled')" 2>/dev/null || echo "unknown")
        echo "   GIL status: $GIL_STATUS"

        if [ "$GIL_STATUS" = "enabled" ]; then
            echo -e "${YELLOW}   Note: GIL is still enabled. To test free-threading:${NC}"
            echo "   - Use Python 3.13 built with --disable-gil"
            echo "   - Or set PYTHON_GIL=0 environment variable"
        fi
    else
        echo -e "${YELLOW}⚠️  python3.13 not found${NC}"
        echo ""
        echo "To install Python 3.13:"
        echo "  uv python install 3.13          # Using uv (recommended)"
        echo "  brew install python@3.13        # macOS"
        echo "  apt install python3.13          # Ubuntu 24.04+"
        echo ""
        echo -e "${YELLOW}Thread profile tests will be skipped without Python 3.13${NC}"
    fi
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "========================================================================"
echo "Summary"
echo "========================================================================"
echo ""

if [ -d ".venv" ]; then
    echo -e "${GREEN}✓${NC} Python 3.12 environment ready (.venv)"
    echo "   Use for: Process profile, GIL compatibility tests"
else
    echo -e "${RED}✗${NC} Python 3.12 environment missing"
fi

if [ -d ".venv-py313" ]; then
    echo -e "${GREEN}✓${NC} Python 3.13 environment ready (.venv-py313)"
    echo "   Use for: Thread profile, free-threading tests"
else
    echo -e "${YELLOW}⚠${NC}  Python 3.13 environment missing"
    echo "   Thread profile tests will be skipped"
fi

echo ""
echo "Run tests:"
echo "  mix test                           # All tests (auto-skip unavailable)"
echo "  mix test --only python312          # Python 3.12 specific"
echo "  mix test --only python313          # Python 3.13 specific"
echo "  mix test --only multi_pool         # Multi-pool tests"
echo ""
