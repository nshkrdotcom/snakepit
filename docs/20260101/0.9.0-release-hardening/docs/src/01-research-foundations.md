# Research Foundations: Runtime, Shutdown, and Exit Semantics

This document captures core engineering considerations that shape the 0.9.0
refactor scope. The focus is on deterministic lifecycle management, safe exit
behavior, and predictable cleanup of external Python processes.

## 1) BEAM lifecycle and termination semantics

### Key mechanisms

- System.halt/1 delegates to :erlang.halt/1. It terminates the VM immediately.
  It does not run OTP application shutdown callbacks or supervisor shutdown
  sequences. It bypasses :init.stop/1 and at_exit hooks.
- System.stop/1 calls :init.stop/1. It initiates a normal shutdown sequence
  and is asynchronous. The calling process continues unless it waits or blocks.
- Application.stop/1 stops an individual OTP application and runs its
  Application.stop/1 callback. This does not stop the whole VM.
- Process.flag(:trap_exit, true) allows processes to receive exit signals as
  messages and can be used for orderly cleanup. terminate/2 callbacks are not
  guaranteed to run on brutal kill or :erlang.halt.

### Design implications

- Using :erlang.halt/1 is a hard stop and should be reserved for emergency or
  explicit operator intent. It trades correctness and cleanup for certainty.
- System.stop/1 is more cooperative but requires a blocking strategy to
  prevent the caller from continuing (often Process.sleep(:infinity)).
- Application.stop/1 is appropriate when the runtime is embedded and you must
  respect ownership boundaries.
- Any shutdown path that uses :erlang.halt/1 must assume terminate/2 and
  at_exit hooks will not fire. Cleanup must be done before the halt.

## 2) IO, group leader, and broken pipes

### What can go wrong

- IO writes to :standard_io or :standard_error can block or crash if the
  downstream pipe is closed (EPIPE). Wrapper commands (timeout, head, tee)
  commonly close pipes early.
- Flush attempts via :io.put_chars/2 or :io.format/2 can block in a closed-pipe
  scenario, especially during teardown when group leader lifetimes are unclear.
- Logger backends that write to the console can surface the same problems if
  they attempt to flush or sync on shutdown.

### Design implications

- Avoid direct IO writes in shutdown and exit paths. Use Logger with
  best-effort semantics and consider async drop behavior for console backends.
- Exit logic must be safe under closed stdout/stderr. If a hard halt is
  requested, do not attempt IO flush or debug prints.
- If diagnostics are essential, capture them before the shutdown boundary or
  route them to a file backend not tied to the process group pipe.

## 3) OS signals, process groups, and external workers

### Facts

- Python workers are OS processes; their lifecycle is independent of the BEAM.
- SIGTERM allows graceful shutdown; SIGKILL is required for stuck processes.
- Process groups and setsid allow killing a group of workers deterministically.
- Kill commands and /proc inspection are platform-sensitive and need careful
  fallback logic.

### Design implications

- Cleanup should be tiered: SIGTERM, wait, then SIGKILL, then last-resort
  scan for orphans.
- OS cleanup should be idempotent and should not depend on VM shutdown
  callbacks firing.
- Process registry and run-id tagging are critical to preventing collateral
  kills and to allow targeted cleanup.

## 4) Script runners, Mix, and wrapper commands

### Runtime contexts

- mix run executes within a fresh VM by default; it halts automatically after
  the script returns unless --no-halt is used.
- Scripts invoked by wrapper commands (timeout, systemd, docker) add another
  layer of signal handling that can close pipes or send SIGTERM/SIGKILL.
- mix run --no-halt is intended for long-running systems and changes exit
  expectations.

### Design implications

- For normal scripts, returning from run_as_script should be sufficient to
  exit the VM, provided no long-lived processes remain.
- Forced halts should be optional and used only when run_as_script is
  embedded into environments that would otherwise keep the VM alive.
- Script runners should allow selection of exit behavior and document when
  each mode is appropriate.

## 5) Supervisors, terminate/2, and cleanup reliability

### Facts

- terminate/2 is not called on :kill, :brutal_kill, or :erlang.halt.
- terminate/2 can be skipped if a process exits normally without trapping
  exits, or if the supervisor itself crashes.

### Design implications

- Cleanup must not rely exclusively on terminate/2. A dedicated cleanup module
  (or system-wide shutdown handler) should be used for emergency scenarios.
- The application stop callback is a better place for cleanup than terminate/2
  if a graceful shutdown path is possible.

## 6) Reliability principles for a cross-language bridge

- Deterministic lifecycle: start/stop should be explicit and observable.
- Ownership boundaries: only stop what you started; avoid side effects in
  embedded runtimes.
- Idempotent cleanup: repeated cleanup passes should be safe.
- Observable state: log the chosen exit mode, cleanup phase, and results.
- Testable exit behavior: design exit modes to be testable via external
  harnesses (System.cmd + wrapper pipes).

