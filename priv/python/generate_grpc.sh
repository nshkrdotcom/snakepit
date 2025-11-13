#!/bin/bash
# Generate Python gRPC code from protobuf definitions using the local virtualenv when present.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${SCRIPT_DIR}"

VENV_PYTHON="${PROJECT_ROOT}/.venv/bin/python3"

if [[ -x "${VENV_PYTHON}" ]]; then
  PYTHON_BIN="${VENV_PYTHON}"
else
  PYTHON_BIN="$(command -v python3 || command -v python || true)"
fi

if [[ -z "${PYTHON_BIN}" ]]; then
  echo "❌ Unable to find a Python interpreter for gRPC generation." >&2
  echo "   Ensure .venv exists or python3 is on PATH." >&2
  exit 1
fi

echo "➡️  Using ${PYTHON_BIN} for gRPC code generation"

"${PYTHON_BIN}" -m grpc_tools.protoc \
  -I../proto \
  --python_out=. \
  --pyi_out=. \
  --grpc_python_out=. \
  ../proto/snakepit_bridge.proto

echo "✅ gRPC code generation complete (output in priv/python)"
