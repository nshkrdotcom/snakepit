#!/usr/bin/env bash
# Interactive menu wrapper for common Snakepit scripts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

run_script() {
  local script_path="$1"
  shift

  if [ ! -x "$script_path" ]; then
    echo "Script not found or not executable: $script_path" >&2
    return 1
  fi

  bash "$script_path" "$@"
}

while true; do
  cat <<'MENU'
==========================================
 Snakepit Utility Menu
==========================================
1) Bootstrap toolchain (mix snakepit.setup)
2) Run environment doctor (mix snakepit.doctor)
3) Install protoc toolchain (Ubuntu/Debian)
4) Run integration tests
5) Setup test Python envs (3.12/3.13)
6) Verify Python 3.13 env
q) Quit
MENU
  read -rp "Select an option: " choice

  case "$choice" in
    1)
      (cd "$PROJECT_ROOT" && mix snakepit.setup) || true
      ;;
    2)
      (cd "$PROJECT_ROOT" && mix snakepit.doctor) || true
      ;;
    3)
      run_script "$SCRIPT_DIR/install_protoc_ubuntu.sh" || true
      ;;
    4)
      run_script "$SCRIPT_DIR/run_integration_tests.sh" || true
      ;;
    5)
      run_script "$SCRIPT_DIR/setup_test_pythons.sh" || true
      ;;
    6)
      run_script "$SCRIPT_DIR/verify_python313.sh" || true
      ;;
    q|Q)
      echo "Bye."
      exit 0
      ;;
    *)
      echo "Invalid selection."
      ;;
  esac
done
