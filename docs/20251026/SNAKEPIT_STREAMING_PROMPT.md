# Snakepit Streaming Stabilization Prompt

## Goals
- Bring the **Snakepit** repo’s gRPC streaming support to a working, tested state.
- Ship a regression-test that exercises streaming end-to-end (Elixir ⇄ Python worker).
- Provide a runnable example that visibly streams five timed chunks from Python back to Elixir.
- Publish the updated Snakepit package before returning to Snakebridge integration work.

## Required Reading / Reference Material
Review these files before you start making changes:

1. `README.md` – project overview and high-level goals.
2. `README_GRPC.md` – bridge design, capabilities, and expected streaming behaviour.
3. `docs/GRPC_QUICK_REFERENCE.md` – method signatures and adapter expectations.
4. `lib/snakepit.ex` – top-level streaming APIs (`execute_stream/4`, `execute_in_session_stream/5`).
5. `lib/snakepit/pool/pool.ex` – how workers are checked out/in for streaming calls.
6. `lib/snakepit/grpc_worker.ex` – the worker process that invokes adapter `grpc_execute_stream/5`.
7. `lib/snakepit/adapters/grpc_python.ex` – adapter implementation that calls into the Python bridge.
8. `priv/python/grpc_server.py` – Python async gRPC server (process mode).
9. `priv/python/grpc_server_threaded.py` – Python threaded gRPC server (threaded mode).
10. `priv/proto/snakepit_bridge.proto` + generated files (for message definitions and handler registration).
11. Any existing streaming-related docs in `docs/2025*` or `docs/archive/**` that mention “stream” or “async_generator”.

## Deliverables
1. **Streaming regression tests** inside the Snakepit repo (likely in `test/`):
   - Minimum: an integration test that starts the gRPC worker, invokes `Snakepit.execute_stream/4`, and asserts that multiple chunks arrive via a callback or stream consumer.
   - Cover both success and failure (e.g., worker not supporting streaming).
2. **Functional streaming implementation**:
   - Ensure `priv/python/grpc_server.py` and `priv/python/grpc_server_threaded.py` bridge async generators correctly. The queue-backed synchronous iterator approach is acceptable; just make sure it’s production-quality (no debug logging, clean shutdown, error propagation).
   - Confirm `Snakepit.GRPC.Client.execute_streaming_tool/5` and `Snakepit.GRPCWorker` behave correctly.
3. **Real streaming example** (inside Snakepit repo, e.g., `examples/`):
   - A script or Mix task that starts Snakepit, calls a Python tool which yields five chunks (`1..5`) with a short `time.sleep` between them, and prints the arriving chunks.
4. **Documentation updates**:
   - Update relevant docs (`README_GRPC.md`, quick reference, or a new doc) to explain how to use streaming, how to run the example, and the new tests.
5. **Publishable state**:
   - `mix test` (with the new streaming test) passes.
   - Example runs cleanly.
   - No debug logging left behind.

## Work Plan Outline
1. **Reset Snakepit** – make sure the repo is clean (`git checkout . && git clean -fd` if needed).
2. **Understand the current failure**:
   - Reproduce with `mix run examples/...` or the existing Snakebridge example (now pointing at the freshly reset repo).
   - Trace where the async generator breaks (`priv/python/grpc_server.py` handler, stub registration in generated code, etc.).
3. **Implement streaming fix**:
   - Use a queue or other mechanism so the gRPC handler returns a synchronous iterator that drains the async generator safely.
   - Ensure cancellation / shutdown paths are handled (worker check-in, queue sentinel, context abort).
4. **Add regression tests**:
   - Create `test/snakepit_streaming_test.exs` (or similar) that spins up Snakepit (maybe via `Snakepit.run_as_script/1`), issues a streaming command, collects chunks, and asserts on them.
   - Consider using a stub adapter or the Python showcase adapter with a deterministic tool.
5. **Create streaming example**:
   - New sample script: e.g., `examples/stream_progress_demo.exs`.
   - Python side: either extend `ShowcaseAdapter` or add a minimal adapter that yields `1..5` with `time.sleep`.
   - Document how to run (`mix run examples/stream_progress_demo.exs`).
6. **Cleanup & Docs**:
   - Remove temporary logs.
   - Update docs with instructions.
7. **Verify & Publish**:
   - `mix test`, `mix format --check-formatted`, etc.
   - Tag/publish (as appropriate for your release process).

## Testing Checklist
- `mix test` (should include the new streaming test).
- `pytest` (if Python side has unit tests; run `make test-python` or `./test_python.sh` if available).
- Run the new streaming example (`mix run examples/stream_progress_demo.exs`).
- Optionally, run the old failing example (e.g., Snakebridge’s `examples/test_streaming_simple.exs` after pointing it at the updated Snakepit) to confirm the regression is gone.

## Operational Tips
- Use a controlled Mix install directory when scripting (`MIX_INSTALL_DIR=/tmp/snakepit_mix_install mix run …`) so the Python files you edit are truly the ones executed.
- After Python changes, delete the corresponding `__pycache__` directories to avoid stale bytecode.
- Keep `/tmp/python_worker_debug.log` (or similar) handy during development, but remove debug logging before publishing.

> Once all the above is complete and validated inside Snakepit, come back to Snakebridge and rerun its streaming example using the newly published Snakepit release.

