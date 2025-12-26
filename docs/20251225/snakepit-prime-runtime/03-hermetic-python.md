# 03 - Hermetic Python Runtime (uv-managed)

## Goal

Provide a managed Python interpreter so Snakepit does not depend on system Python. This ensures reproducibility and reduces deployment fragility.

## Managed Mode

```elixir
config :snakepit,
  python_runtime: [
    managed: true,
    version: "3.11.7",
    install_dir: "priv/snakepit/runtime"
  ]
```

In managed mode:

- `mix snakepit.setup` runs `uv python install <version>`
- Interpreter is installed under `install_dir`
- The interpreter hash is recorded in `snakebridge.lock`

## Runtime Selection Order

1. Managed interpreter (if enabled)
2. `python_executable` config override
3. System `python3`

If managed mode is enabled but installation is missing, Snakepit fails fast with install guidance.

## Lockfile Integration

Lockfile fields:

- `python_runtime_hash`
- `python_version`
- `python_platform`

If any differ from the current runtime, SnakeBridge invalidates adapters.

## Offline / CI Behavior

In CI:

- Use managed interpreter cache or preinstall step
- No reliance on system Python
- Deterministic runs when lockfile matches

## Failure Modes

- `uv` missing: fail with guidance
- install dir not writable: fail
- version not found: fail

## Tests

- Unit test: runtime selection order
- Integration test: managed interpreter path returns usable Python

