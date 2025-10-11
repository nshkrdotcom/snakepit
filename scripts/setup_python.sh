#!/usr/bin/env bash
# Setup Python dependencies for Snakepit
# Uses uv by default (faster), falls back to pip if uv not available

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PYTHON_DIR="$PROJECT_ROOT/priv/python"

echo "🐍 Setting up Python dependencies for Snakepit..."
echo "📁 Python directory: $PYTHON_DIR"

# Check if uv is available
if command -v uv &> /dev/null; then
    echo "✅ Using uv (fast Python package installer)"
    INSTALLER="uv pip"
else
    echo "⚠️  uv not found, falling back to pip"
    echo "💡 Install uv for faster installs: curl -LsSf https://astral.sh/uv/install.sh | sh"
    INSTALLER="pip"
fi

# Change to Python directory
cd "$PYTHON_DIR"

# Check if requirements.txt exists
if [ ! -f "requirements.txt" ]; then
    echo "❌ Error: requirements.txt not found in $PYTHON_DIR"
    exit 1
fi

# Check if we're in a virtual environment
if [ -z "$VIRTUAL_ENV" ]; then
    echo "⚠️  Not in a virtual environment"
    echo "💡 Recommended: Create a venv first:"
    echo "   python3 -m venv .venv"
    echo "   source .venv/bin/activate"
    echo ""
    read -p "Continue with system Python? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
else
    echo "✅ Virtual environment detected: $VIRTUAL_ENV"
fi

# Install dependencies
echo "📦 Installing Python dependencies..."
$INSTALLER install -r requirements.txt

# Verify installation
echo ""
echo "🔍 Verifying installation..."
python3 -c "import grpc; print(f'✅ gRPC {grpc.__version__} installed')" || echo "❌ gRPC not found"
python3 -c "import google.protobuf; print(f'✅ Protobuf installed')" || echo "❌ Protobuf not found"

echo ""
echo "✅ Python setup complete!"
echo ""
echo "Next steps:"
echo "1. Generate protocol buffers: make proto-python"
echo "2. Run tests: mix test"
echo "3. Try examples: elixir examples/grpc_basic.exs"
