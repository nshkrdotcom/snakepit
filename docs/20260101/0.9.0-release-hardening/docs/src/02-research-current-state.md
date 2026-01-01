# Research: Current State Audit (Snakepit)

This document summarizes the current behavior of Snakepit's script lifecycle,
shutdown, and cleanup pipeline, with concrete file references.

## 1) run_as_script/2 lifecycle (lib/snakepit.ex)

- run_as_script/2 is the main script wrapper.
- It starts Snakepit, optionally waits for the pool, runs the user function,
  then executes stop and cleanup logic.
- It optionally calls maybe_halt/2 with a boolean `:halt` option or the
  SNAKEPIT_SCRIPT_HALT env var.
- It calls Application.stop(:snakepit) unconditionally, regardless of whether
  the application was already running.

Implication: Embedded usage (Snakepit already started) can be disrupted by
run_as_script stopping the app. This is a potential ownership violation.

## 2) Exit behavior (lib/snakepit.ex)

- maybe_halt/2 is the only hard-exit hook in core runtime.
- Current diff shows an IO write to :standard_error before halting.
- The prior version also attempted IO flush via :io.put_chars.

Implication: IO at shutdown is risky when stdout/stderr is closed or when a
wrapper command (timeout) closes pipes early. The exit path should avoid IO.

## 3) Example bootstrap defaults (examples/mix_bootstrap.exs)

- Snakepit.Examples.Bootstrap.run_example/2 defaults to `halt: true`.
- This means all example scripts request a forced VM halt.

Implication: Any IO during halt, or a closed pipe in a wrapper, can produce
hangs or hard-to-debug behavior. This is likely related to the DSPex issue.

## 4) Application stop behavior (lib/snakepit/application.ex)

- Application.stop/1 calls maybe_cleanup_on_stop, which runs RuntimeCleanup
  with timeouts.
- This provides a best-effort shutdown cleanup for external processes.

Implication: Cleanup on stop is already present but depends on the app stop
path being taken (not :erlang.halt). Hard halts bypass this.

## 5) Emergency cleanup (lib/snakepit/pool/application_cleanup.ex)

- ApplicationCleanup is a GenServer that traps exits and runs terminate/2
  during shutdown. It scans for orphaned Python processes.

Implication: terminate/2 is not guaranteed on :erlang.halt. This is a safety
net for graceful shutdown only.

## 6) Cleanup module (lib/snakepit/runtime_cleanup.ex)

- RuntimeCleanup performs SIGTERM -> wait -> SIGKILL escalation.
- It relies on ProcessRegistry to target only current run processes.

Implication: This is robust but only effective if the shutdown path is reached
and has time to execute. Hard halts should occur after cleanup or not at all.

## 7) Documentation and env vars (guides, docs)

- guides/getting-started.md and guides/production.md document run_as_script/2
  and its `:halt` option.
- guides/production.md documents SNAKEPIT_SCRIPT_HALT env var.
- docs/20251229/documentation-overhaul/01-core-api.md describes :halt as
  System.halt/1.

Implication: Docs describe a halt behavior but do not explain hard vs soft
exit, nor do they describe IO-safe shutdown behavior or wrapper interaction.

## 8) Tests and examples

- test/run_bridge_tests.exs uses System.halt to return exit status for scripts.
- examples/threaded_profile_demo.exs uses System.halt(1) on missing Python.

Implication: These are CLI-level exits and are appropriate, but they do not
validate run_as_script behavior under wrapper scripts or broken pipes.

