#!/usr/bin/env bash
# Non-interactive installer for protoc on Ubuntu/Debian.
# Installs protoc, protoc-gen-elixir, and Python gRPC tools.

set -euo pipefail

echo "Installing Protocol Buffers toolchain (non-interactive)..."

if ! command -v apt-get >/dev/null 2>&1; then
  echo "Error: apt-get not found (expected Ubuntu/Debian). Aborting." >&2
  exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="${SUDO:-sudo}"
fi

echo "Updating package list..."
$SUDO apt-get update -y

echo "Installing protobuf-compiler..."
$SUDO apt-get install -y protobuf-compiler

echo "Ensuring protoc-gen-elixir is available..."
if ! command -v protoc-gen-elixir >/dev/null 2>&1; then
  mix escript.install hex protobuf --force
fi

# Ensure escripts path is in PATH for this shell; caller can persist if desired.
ESCRIPT_PATH="$HOME/.mix/escripts"
if [ -d "$ESCRIPT_PATH" ] && [[ ":${PATH}:" != *":${ESCRIPT_PATH}:"* ]]; then
  export PATH="$ESCRIPT_PATH:$PATH"
fi

echo "Installing Python gRPC tools..."
python3 -m pip install --user --upgrade grpcio-tools protobuf

echo
echo "Verifying installations..."
echo "========================="
command -v protoc >/dev/null 2>&1 && protoc --version || echo "✗ protoc not found"
command -v protoc-gen-elixir >/dev/null 2>&1 && echo "✓ protoc-gen-elixir available" || echo "✗ protoc-gen-elixir not found"
python3 -m grpc_tools.protoc --version >/dev/null 2>&1 && echo "✓ python grpc_tools.protoc available" || echo "✗ python grpc_tools.protoc not found"

echo "Done."

echo
echo "Installation complete!"
echo

# Source bashrc if PATH was updated
if [[ ":$PATH:" != *":$HOME/.mix/escripts:"* ]]; then
    echo "Note: Please run 'source ~/.bashrc' or restart your terminal for PATH changes to take effect"
fi

echo "You can now generate protobuf files with:"
echo "  - Elixir: mix grpc.gen"
echo "  - Python: make proto-python (or ./priv/python/generate_grpc.sh)"
