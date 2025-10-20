# Snakepit 0.6.1 Testing Matrix

All commands assume you are in the repository root (`snakepit/`).

## Elixir test suite

```
mix test --color
```

Runs every Elixir unit, integration, and doctest. The new heartbeat timeout regression (`test/snakepit/grpc/heartbeat_end_to_end_test.exs`) executes here and requires a Unix-like OS.

## Python bridge tests

First ensure the virtualenv is available:

```
python3 -m venv .venv
.venv/bin/pip install -r priv/python/requirements.txt
```

Then run the bridge tests with correlation coverage enabled:

```
SNAKEPIT_OTEL_CONSOLE=0 PYTHONPATH=priv/python .venv/bin/pytest priv/python/tests -q
```

This executes the full 41-test suite, including `test_proxy_outgoing_metadata_carries_correlation`, which verifies the Python bridge propagates the active correlation id into outbound gRPC metadata.

## make test (legacy)

```
make test
```

`make test` now auto-detects `.venv/bin/python` (falling back to `python3`/`python`) and runs:

1. `PYTHONPATH=priv/python <python> -m pytest priv/python/tests`
2. `mix test --color`

Run `python3 -m venv .venv` first if you rely on the local virtualenv. For CI integration, you can still invoke `mix test` and the explicit pytest command separately.
