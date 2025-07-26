#!/bin/bash
# Mock gRPC server that immediately outputs the ready message and exits
port=${1:-50051}
# Check if --port argument was provided
for i in "$@"; do
  case $i in
    --port=*)
      port="${i#*=}"
      shift
      ;;
    --port)
      shift
      port="$1"
      shift
      ;;
  esac
done

echo "GRPC_READY:$port"
# Keep running to simulate a server
while true; do
  sleep 1
done