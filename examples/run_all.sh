#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

RUN_SETUP=0
RUN_DOCTOR=1
RUN_SHOWCASE=1
RUN_LOADTEST=1

usage() {
  cat <<'USAGE'
Run all Snakepit examples using mix run.

Usage: examples/run_all.sh [options]

Options:
  --setup          Run mix snakepit.setup before examples
  --skip-doctor    Skip mix snakepit.doctor
  --skip-showcase  Skip examples/snakepit_showcase demo app
  --skip-loadtest  Skip examples/snakepit_loadtest demo app
  --help           Show this help

Environment:
  SNAKEPIT_EXAMPLE_DURATION_MS   Default auto-stop duration for scripted demos (default: 3000)
  SNAKEPIT_AUTO_DEMO_DURATION_MS  Auto-stop duration for bidirectional auto demo (default: 3000)
  SNAKEPIT_SUSTAINED_DURATION_MS  Override sustained load demo duration in ms (default: 15000)
  SNAKEPIT_RUN_TIMEOUT_MS        Per-example timeout in ms (default: 180000, set 0 to disable)
  LOADTEST_BASIC_WORKERS          Loadtest worker count for basic demo (default: 10)
  LOADTEST_STRESS_WORKERS         Loadtest worker count for stress demo (default: 10)
  LOADTEST_BURST_WORKERS          Loadtest worker count for burst demo (default: 10)
  LOADTEST_SUSTAINED_WORKERS      Loadtest worker count for sustained demo (default: 5)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --setup)
      RUN_SETUP=1
      ;;
    --skip-doctor)
      RUN_DOCTOR=0
      ;;
    --skip-showcase)
      RUN_SHOWCASE=0
      ;;
    --skip-loadtest)
      RUN_LOADTEST=0
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

run_cmd() {
  local label="$1"
  shift
  echo ""
  echo "==> ${label}"
  if [[ -n "${TIMEOUT_CMD:-}" ]]; then
    ${TIMEOUT_CMD} "$@"
  else
    "$@"
  fi
}

failures=()

if [[ "${RUN_SETUP}" -eq 1 ]]; then
  if ! run_cmd "mix snakepit.setup" bash -c "cd \"${ROOT_DIR}\" && mix snakepit.setup"; then
    failures+=("mix snakepit.setup")
  fi
fi

if [[ "${RUN_DOCTOR}" -eq 1 ]]; then
  if ! run_cmd "mix snakepit.doctor" bash -c "cd \"${ROOT_DIR}\" && mix snakepit.doctor"; then
    failures+=("mix snakepit.doctor")
  fi
fi

EXAMPLE_SCRIPTS=(
  "examples/grpc_basic.exs"
  "examples/grpc_sessions.exs"
  "examples/grpc_streaming.exs"
  "examples/grpc_concurrent.exs"
  "examples/grpc_advanced.exs"
  "examples/grpc_streaming_demo.exs"
  "examples/stream_progress_demo.exs"
  "examples/bidirectional_tools_demo.exs"
  "examples/bidirectional_tools_demo_auto.exs"
  "examples/threaded_profile_demo.exs"
  "examples/dual_mode/process_vs_thread_comparison.exs"
  "examples/dual_mode/hybrid_pools.exs"
  "examples/dual_mode/gil_aware_selection.exs"
  "examples/lifecycle/ttl_recycling_demo.exs"
  "examples/monitoring/telemetry_integration.exs"
  "examples/telemetry_basic.exs"
  "examples/telemetry_advanced.exs"
  "examples/telemetry_monitoring.exs"
  "examples/telemetry_metrics_integration.exs"
  "examples/structured_errors.exs"
  # v0.8.0 ML Features
  "examples/hardware_detection.exs"
  "examples/crash_recovery.exs"
  "examples/ml_errors.exs"
  "examples/ml_telemetry.exs"
  # v0.8.5 Streaming
  "examples/execute_streaming_tool_demo.exs"
)

EXAMPLE_DURATION_MS="${SNAKEPIT_EXAMPLE_DURATION_MS:-3000}"
AUTO_DEMO_DURATION_MS="${SNAKEPIT_AUTO_DEMO_DURATION_MS:-${EXAMPLE_DURATION_MS}}"
SUSTAINED_DURATION_MS="${SNAKEPIT_SUSTAINED_DURATION_MS:-15000}"
RUN_TIMEOUT_MS="${SNAKEPIT_RUN_TIMEOUT_MS:-180000}"
RUN_TIMEOUT_SECONDS=$(( (RUN_TIMEOUT_MS + 999) / 1000 ))

if [[ "${RUN_TIMEOUT_MS}" =~ ^[0-9]+$ ]] && [[ "${RUN_TIMEOUT_MS}" -gt 0 ]]; then
  if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout --foreground --preserve-status ${RUN_TIMEOUT_SECONDS}"
  elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout --foreground --preserve-status ${RUN_TIMEOUT_SECONDS}"
  else
    TIMEOUT_CMD=""
  fi
else
  TIMEOUT_CMD=""
fi

for script in "${EXAMPLE_SCRIPTS[@]}"; do
  if [[ ! -f "${ROOT_DIR}/${script}" ]]; then
    failures+=("${script} (missing)")
    continue
  fi

  if [[ "${script}" == "examples/bidirectional_tools_demo.exs" || \
        "${script}" == "examples/bidirectional_tools_demo_auto.exs" ]]; then
    if ! run_cmd "${script}" bash -c \
      "cd \"${ROOT_DIR}\" && SNAKEPIT_DEMO_DURATION_MS=${AUTO_DEMO_DURATION_MS} \
       SNAKEPIT_EXAMPLE_DURATION_MS=${EXAMPLE_DURATION_MS} \
       mix run --no-start \"${script}\""; then
      failures+=("${script}")
    fi
    continue
  fi

  if ! run_cmd "${script}" bash -c \
    "cd \"${ROOT_DIR}\" && SNAKEPIT_EXAMPLE_DURATION_MS=${EXAMPLE_DURATION_MS} \
     mix run --no-start \"${script}\""; then
    failures+=("${script}")
  fi
done

if [[ "${RUN_SHOWCASE}" -eq 1 ]]; then
  if ! run_cmd "examples/snakepit_showcase (run_all)" bash -c \
    "cd \"${ROOT_DIR}/examples/snakepit_showcase\" && mix deps.get && \
     mix run --eval 'Snakepit.run_as_script(fn -> SnakepitShowcase.DemoRunner.run_all() end, halt: true)'"; then
    failures+=("examples/snakepit_showcase")
  fi
fi

if [[ "${RUN_LOADTEST}" -eq 1 ]]; then
  LOADTEST_BASIC_WORKERS="${LOADTEST_BASIC_WORKERS:-10}"
  LOADTEST_STRESS_WORKERS="${LOADTEST_STRESS_WORKERS:-10}"
  LOADTEST_BURST_WORKERS="${LOADTEST_BURST_WORKERS:-10}"
  LOADTEST_SUSTAINED_WORKERS="${LOADTEST_SUSTAINED_WORKERS:-5}"

  if ! run_cmd "examples/snakepit_loadtest (basic)" bash -c \
    "cd \"${ROOT_DIR}/examples/snakepit_loadtest\" && mix deps.get && \
     mix run --eval 'Snakepit.run_as_script(fn -> SnakepitLoadtest.Demos.BasicLoadDemo.run(${LOADTEST_BASIC_WORKERS}) end, halt: true)'"; then
    failures+=("examples/snakepit_loadtest basic")
  fi

  if ! run_cmd "examples/snakepit_loadtest (stress)" bash -c \
    "cd \"${ROOT_DIR}/examples/snakepit_loadtest\" && \
     mix run --eval 'Snakepit.run_as_script(fn -> SnakepitLoadtest.Demos.StressTestDemo.run(${LOADTEST_STRESS_WORKERS}) end, halt: true)'"; then
    failures+=("examples/snakepit_loadtest stress")
  fi

  if ! run_cmd "examples/snakepit_loadtest (burst)" bash -c \
    "cd \"${ROOT_DIR}/examples/snakepit_loadtest\" && \
     mix run --eval 'Snakepit.run_as_script(fn -> SnakepitLoadtest.Demos.BurstLoadDemo.run(${LOADTEST_BURST_WORKERS}) end, halt: true)'"; then
    failures+=("examples/snakepit_loadtest burst")
  fi

  if ! run_cmd "examples/snakepit_loadtest (sustained)" bash -c \
    "cd \"${ROOT_DIR}/examples/snakepit_loadtest\" && \
     SNAKEPIT_SUSTAINED_DURATION_MS=${SUSTAINED_DURATION_MS} \
     mix run --eval 'Snakepit.run_as_script(fn -> SnakepitLoadtest.Demos.SustainedLoadDemo.run(${LOADTEST_SUSTAINED_WORKERS}) end, halt: true)'"; then
    failures+=("examples/snakepit_loadtest sustained")
  fi
fi

if [[ "${#failures[@]}" -gt 0 ]]; then
  echo ""
  echo "Examples finished with failures:"
  for failure in "${failures[@]}"; do
    echo " - ${failure}"
  done
  exit 1
fi

echo ""
echo "All examples completed successfully."
