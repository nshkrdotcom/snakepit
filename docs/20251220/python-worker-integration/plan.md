# Plan

Validate what actually works today for same-node Python worker integration, then consolidate scripts/docs around the real flow, bump version+changelog, and finish with full green tests/examples/dialyzer.

## Requirements
- Prove the current integration/installation flow from scripts, mix tasks, docs, and examples.
- Consolidate scripts to prefer `mix run` or mix tasks where it makes sense.
- Update all docs/guides to a single, accurate same-node story plus troubleshooting.
- Bump version in `mix.exs` and `README.md`, add a `CHANGELOG.md` entry dated 2025-12-20.
- Ensure all tests, examples, and dialyzer are green with zero warnings.

## Scope
- In: `scripts/`, `examples/`, `docs/`, `guides/`, `README.md`, `mix.exs`, `CHANGELOG.md`, mix tasks, env checks.
- Out: major architecture changes for remote workers (document only if needed).

## Files and entry points
- `mix.exs`, `README.md`, `CHANGELOG.md`
- `scripts/setup_python.sh`, `scripts/run_integration_tests.sh`, `scripts/tools_menu.sh`, `Makefile`
- `examples/*.exs`, `examples/README.md`
- `guides/INSTALLATION.md`, `docs/PRODUCTION_DEPLOYMENT_CHECKLIST.md`, `docs/TEST_AND_EXAMPLE_STATUS.md`, `docs/EXAMPLE_TEST_RESULTS.md`
- `lib/mix/tasks/*`, `lib/snakepit/env_doctor.ex`, `lib/snakepit/pool/pool.ex`
- `priv/python/*`, `priv/python/tests/*`

## Data model / API changes
- None expected (config/docs/task wiring only).

## Action items
[ ] Baseline discovery: confirm working flows and contradictions.
    - Commands: `rg -n "elixir examples|Mix.install|base_port|port_range|python_adapter"` and `rg -n "snakepit.setup|snakepit.doctor|grpc.gen" docs guides scripts examples README.md`
    - Inspect setup/test scripts, mix tasks, Python server entry points.
    - Run: `mix snakepit.setup`, `mix snakepit.doctor`, and a couple examples with `mix run`.
[ ] Consolidate scripts: route setup/doctor/status to mix tasks; standardize example execution on `mix run`, add a common bootstrap if needed.
[ ] Align docs/guides: update integration story and installation steps to reflect real behavior, same-node constraint, and troubleshooting.
[ ] Version bump and changelog: increment `mix.exs`, update `README.md` version mentions, add `CHANGELOG.md` entry dated 2025-12-20.
[ ] Validation pass and fixes: run full tests, examples, and dialyzer; eliminate warnings.

## Testing and validation
- `mix deps.get && mix compile`
- `mix snakepit.setup`
- `mix snakepit.doctor`
- `mix test`
- `mix test --only python_integration`
- `mix test --only integration`
- `pytest priv/python/tests -q` or `./test_python.sh -q`
- `mix dialyzer`
- `mix run --no-start examples/<example>.exs` or `mix run --no-start examples/run_examples.exs`

## Risks and edge cases
- Some examples or docs may still assume `Mix.install`; converting to `mix run` may need a shared bootstrap.
- CI or external users may rely on script names/behavior; keep compatibility or document changes.
- Dialyzer may surface existing warnings unrelated to changes.

## Open questions
- Confirm target version bump (e.g., current `x.y.z` to `x.y.(z+1)`).
- Any scripts we must keep stable for external automation?
