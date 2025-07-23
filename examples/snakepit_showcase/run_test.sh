#!/bin/bash
# Run test and capture Python logs
export PYTHONUNBUFFERED=1
timeout 15 mix run test_minimal.exs 2>&1 | grep -E "(ExecuteStreamingTool|Creating SessionContext|Creating adapter|Processing sync|Got chunk|Yielding|TIMEOUT|CHUNK RECEIVED)" || true