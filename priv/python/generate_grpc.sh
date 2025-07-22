#!/bin/bash
# Generate Python gRPC code from protobuf definitions

cd "$(dirname "$0")"

# Ensure the grpc directory exists
mkdir -p snakepit_bridge/grpc

# Generate Python code from protobuf
python -m grpc_tools.protoc \
  -I../proto \
  --python_out=snakepit_bridge/grpc \
  --pyi_out=snakepit_bridge/grpc \
  --grpc_python_out=snakepit_bridge/grpc \
  ../proto/snakepit_bridge.proto

# Touch __init__.py to ensure it's a package
touch snakepit_bridge/grpc/__init__.py

echo "gRPC code generation complete!"
echo "Generated files in: snakepit_bridge/grpc/"