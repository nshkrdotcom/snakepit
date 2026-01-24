#!/usr/bin/env python3
"""
Test-only gRPC server shim for Snakepit process-group behavior.

This is NOT a real gRPC server.
It exists to:
  - optionally create a new process group (via os.setsid) when SNAKEPIT_PROCESS_GROUP=1
  - write the readiness file expected by Snakepit
  - spawn a long-lived child process so tests can verify group kill semantics
"""

import argparse
import os
import signal
import subprocess
import sys
import time


def maybe_create_process_group() -> bool:
    enabled = os.environ.get("SNAKEPIT_PROCESS_GROUP", "").lower() in ("1", "true", "yes", "on")
    if not enabled:
        return False

    if os.name != "posix" or not hasattr(os, "setsid"):
        return False

    # If we're already a group leader (e.g. spawned under setsid), don't warn.
    try:
        if os.getpid() == os.getpgrp():
            return True
    except Exception:
        pass

    try:
        os.setsid()
        return True
    except Exception:
        return False


def write_ready_file(port: int) -> None:
    ready_file = os.environ.get("SNAKEPIT_READY_FILE")
    if not ready_file:
        raise RuntimeError("SNAKEPIT_READY_FILE not set")

    tmp_path = f"{ready_file}.tmp"
    with open(tmp_path, "w", encoding="utf-8") as handle:
        handle.write(str(port))
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp_path, ready_file)


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--port", type=int, default=0)
    # Ignore unknown args added by Snakepit (elixir address, run id, etc.)
    args, _unknown = parser.parse_known_args()

    delay_setsid_ms = os.environ.get("SNAKEPIT_TEST_DELAY_SETSID_MS")
    if delay_setsid_ms:
        try:
            time.sleep(max(int(delay_setsid_ms), 0) / 1000.0)
        except Exception:
            pass

    maybe_create_process_group()

    child_pid_file = os.environ.get("SNAKEPIT_CHILD_PID_FILE")
    sleep_path = os.environ.get("SNAKEPIT_TEST_SLEEP_PATH") or "/bin/sleep"

    child = None
    if child_pid_file:
        # Spawn a child so Elixir tests can verify process-group kill reaches grandchildren.
        child = subprocess.Popen([sleep_path, "300"])
        with open(child_pid_file, "w", encoding="utf-8") as handle:
            handle.write(str(child.pid))

    delay_ready_ms = os.environ.get("SNAKEPIT_TEST_DELAY_READY_MS")
    if delay_ready_ms:
        try:
            time.sleep(max(int(delay_ready_ms), 0) / 1000.0)
        except Exception:
            pass

    write_ready_file(args.port)

    # Stay alive until terminated. Group kill should signal both parent and child.
    def _handle_signal(_signum, _frame):
        sys.exit(0)

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    try:
        while True:
            time.sleep(1)
    finally:
        if child is not None:
            try:
                child.terminate()
            except Exception:
                pass

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
