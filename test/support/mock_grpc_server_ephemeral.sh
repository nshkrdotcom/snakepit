#!/bin/bash
# Mock gRPC server that reports a different actual port than the requested one.

# Default ports
requested_port=0
actual_port=${SNAKEPIT_EPHEMERAL_ACTUAL_PORT:-61234}

# Allow overriding via --port CLI flag (just to capture the requested value)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      requested_port="$2"
      shift 2
      ;;
    --port=*)
      requested_port="${1#*=}"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

ready_file="${SNAKEPIT_READY_FILE:-}"
if [ -z "$ready_file" ]; then
  exit 1
fi

printf "%s" "$actual_port" > "$ready_file"

# Keep process alive so the BEAM Port stays open
tail -f /dev/null
