# Repository Guidelines

> Updated for Snakepit v0.7.2

## Project Structure & Module Organization
Snakepit is an Elixir OTP application under `lib/`, split into supervisors, gRPC adapters, and bridge utilities. Shared configs live in `config/` and generated assets land in `_build/`. Protocol buffers reside in `priv/proto/`; Python bridge code and fixtures are under `priv/python/` with pytest suites in `priv/python/tests/`. Integration samples sit in `examples/`, load-testing setups in `bench/`, while `specs/` contains design references. Use `docs/` and `guides/` for architecture and operations notes, and keep reusable scripts inside `scripts/`.

## Build, Test, and Development Commands
- `mix snakepit.setup` bootstraps Elixir deps and Python assets for the repo.
- `mix snakepit.doctor` validates the local environment and adapter imports.
- `mix deps.get && mix compile` installs Elixir deps and compiles the app.
- `mix grpc.gen` rebuilds the Elixir gRPC stubs from `priv/proto/snakepit_bridge.proto`.
- `make proto-python` or `./priv/python/generate_grpc.sh` regenerates Python gRPC bindings.
- `mix snakepit.status` reports pool size, queue depth, and error counts.
- `mix snakepit.gen.adapter` scaffolds a Python adapter under `priv/python/`.
- `mix test` runs the Elixir suite; `make test` chains Python pytest runs and Elixir tests.
- `./test_python.sh` runs pytest with automatic `.venv` setup and protobuf regeneration.
- `mix dialyzer` verifies types using the PLTs in `priv/plts`.
- `mix docs` produces HexDocs-ready API docs into `doc/`.
- `./examples/run_all.sh` runs the full example suite; use `--skip-showcase` or `--skip-loadtest` to trim.

## Coding Style & Naming Conventions
Elixir code uses `mix format` with the repo `.formatter.exs`; stick to two-space indentation, snake_case for functions, and `Snakepit.*` module namespaces that mirror directory layout. Tests belong in `*_test.exs` files colocated in `test/`. Python bridge modules follow PEP 8, prefer `snakepit_bridge_*` naming, and rely on the formatter bundled with your editor—run `ruff` or `black` if configured locally. Keep protocol filenames stable (`snakepit_bridge.proto`) to avoid mismatched generated code.

## Testing Guidelines
Default to `mix test --color --trace` for focused Elixir runs, and use `mix test --cover` when validating coverage before release. Property-based cases rely on `StreamData`; place generators beside the tests that consume them. Run `pytest priv/python/tests -q` after touching bridge code, and regenerate stubs before exercising cross-language flows. Document new regression suites in `docs/code-standards/` and update `README_TESTING.md` when workflows change.

## Commit & Pull Request Guidelines
Follow the concise, imperative style seen in `git log` (e.g., `add generic adapter design`). Group related file updates into a single commit, summarising behaviour changes rather than implementation details. Pull requests should include: a problem statement, highlights of the solution, any protocol regeneration steps taken, and test evidence (`mix test`, `pytest`). Link tracking issues, attach logs or screenshots for runtime regressions, and call out follow-up work explicitly in a checklist.
