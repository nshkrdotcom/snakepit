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

ready_file="${SNAKEPIT_READY_FILE:-}"
if [ -z "$ready_file" ]; then
  exit 1
fi

printf "%s" "$port" > "$ready_file"

# Keep running to simulate a server
tail -f /dev/null
