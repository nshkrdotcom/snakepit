#!/bin/bash
# Install protoc (Protocol Buffers compiler) on Ubuntu
# This script installs protoc and the necessary plugins for Elixir and Python

set -e

echo "Installing Protocol Buffers compiler (protoc) on Ubuntu..."

# Check if running on Ubuntu/Debian
if ! command -v apt-get &> /dev/null; then
    echo "Error: This script is designed for Ubuntu/Debian systems with apt-get"
    exit 1
fi

# Check if protoc is already installed
if command -v protoc &> /dev/null; then
    CURRENT_VERSION=$(protoc --version | cut -d' ' -f2)
    echo "protoc is already installed (version $CURRENT_VERSION)"
    read -p "Do you want to reinstall/update? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Keeping existing installation"
    else
        echo "Proceeding with reinstallation..."
    fi
else
    echo "protoc not found, proceeding with installation..."
fi

# Update package list
echo "Updating package list..."
sudo apt-get update

# Install protobuf-compiler and related tools
echo "Installing protobuf-compiler..."
sudo apt-get install -y protobuf-compiler

# Install protoc-gen-elixir plugin
echo "Checking for Elixir protoc plugin..."
if ! command -v protoc-gen-elixir &> /dev/null; then
    echo "Installing protoc-gen-elixir..."
    mix escript.install hex protobuf --force
    
    # Add escript path to PATH if not already there
    ESCRIPT_PATH="$HOME/.mix/escripts"
    if [[ ":$PATH:" != *":$ESCRIPT_PATH:"* ]]; then
        echo "Adding $ESCRIPT_PATH to PATH..."
        echo 'export PATH="$HOME/.mix/escripts:$PATH"' >> ~/.bashrc
        export PATH="$ESCRIPT_PATH:$PATH"
    fi
else
    echo "protoc-gen-elixir already installed"
fi

# Install Python gRPC tools
echo "Installing Python gRPC tools..."
pip3 install --user grpcio-tools

# Verify installations
echo
echo "Verifying installations..."
echo "========================="

if command -v protoc &> /dev/null; then
    echo "✓ protoc version: $(protoc --version)"
else
    echo "✗ protoc not found in PATH"
fi

if command -v protoc-gen-elixir &> /dev/null; then
    echo "✓ protoc-gen-elixir found"
else
    echo "✗ protoc-gen-elixir not found in PATH"
fi

if python3 -m grpc_tools.protoc --version &> /dev/null 2>&1; then
    echo "✓ Python gRPC tools installed"
else
    echo "✗ Python gRPC tools not found"
fi

echo
echo "Installation complete!"
echo

# Source bashrc if PATH was updated
if [[ ":$PATH:" != *":$HOME/.mix/escripts:"* ]]; then
    echo "Note: Please run 'source ~/.bashrc' or restart your terminal for PATH changes to take effect"
fi

echo "You can now generate protobuf files with:"
echo "  - Elixir: mix grpc.gen"
echo "  - Python: python3 priv/python/generate_proto.py"