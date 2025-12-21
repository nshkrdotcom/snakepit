#!/usr/bin/env bash
# Non-interactive Python setup for Snakepit.
# Creates .venv (unless VENV_PATH is set) and installs priv/python requirements.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PYTHON_DIR="$PROJECT_ROOT/priv/python"
VENV_PATH="${VENV_PATH:-$PROJECT_ROOT/.venv}"

echo "🐍 Setting up Python dependencies (non-interactive)"
echo "📁 Project root: $PROJECT_ROOT"
echo "📦 Python package dir: $PYTHON_DIR"
echo "🧠 Virtualenv: $VENV_PATH"

if command -v mix >/dev/null 2>&1; then
  echo "➡️  Delegating to mix snakepit.setup (preferred)"
  (cd "$PROJECT_ROOT" && mix snakepit.setup)
  exit 0
fi

if [ ! -f "$PYTHON_DIR/requirements.txt" ]; then
  echo "requirements.txt missing at $PYTHON_DIR" >&2
  exit 1
fi

# Create venv if missing
if [ ! -d "$VENV_PATH" ]; then
  if command -v uv >/dev/null 2>&1; then
    echo "✅ Creating venv with uv..."
    uv venv "$VENV_PATH"
  else
    echo "⚠️  uv not found; using python3 -m venv"
    python3 -m venv "$VENV_PATH"
  fi
fi

PYTHON_BIN="$VENV_PATH/bin/python"
PIP_BIN="$VENV_PATH/bin/pip"

if [ ! -x "$PYTHON_BIN" ]; then
  echo "Virtualenv at $VENV_PATH is missing python executable" >&2
  exit 1
fi

echo "📦 Installing dependencies into $VENV_PATH..."
"$PIP_BIN" install --upgrade pip >/dev/null
"$PIP_BIN" install -r "$PYTHON_DIR/requirements.txt"

echo "🔍 Verifying installation..."
"$PYTHON_BIN" - <<'PY'
import grpc, google.protobuf
print(f"grpcio: {grpc.__version__}")
print(f"protobuf: {google.protobuf.__version__}")
PY

echo "✅ Python setup complete."
