#!/bin/bash
# Generate Python gRPC code from protobuf definitions

cd "$(dirname "$0")"

# Generate directly to the python directory

# Generate Python code from protobuf
python -m grpc_tools.protoc \
  -I../proto \
  --python_out=. \
  --pyi_out=. \
  --grpc_python_out=. \
  ../proto/snakepit_bridge.proto

# No need for __init__.py in root directory

echo "gRPC code generation complete!"
echo "Generated files in: ./"