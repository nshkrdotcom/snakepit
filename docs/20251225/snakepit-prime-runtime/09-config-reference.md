# 09 - Configuration Reference (Snakepit Prime Runtime)

This reference documents new runtime configuration additions for the 0.7.(x+1) line. Existing pool, adapter, and telemetry config continues to work.

## Minimal Example

```elixir
config :snakepit,
  pooling_enabled: true,
  adapter_module: Snakepit.Adapters.GRPCPython,
  adapter_args: ["--adapter", "your_adapter_module"],
  pool_size: 8,
  zero_copy: [enabled: true],
  crash_barrier: [enabled: true]
```

## Python Runtime (Hermetic Optional)

```elixir
config :snakepit, :python, [
  strategy: :uv,                # :uv | :system
  managed: true,                # install a local Python if true
  python_version: "3.11.8",
  runtime_dir: "priv/snakepit/python",
  cache_dir: "priv/snakepit/python/cache",
  uv_path: nil,                 # auto-detect if nil
  extra_env: %{"PYTHONNOUSERSITE" => "1"}
]
```

Notes:
- `managed: true` installs a local interpreter into `runtime_dir`.
- `strategy: :system` uses the system Python and ignores `runtime_dir`.
- Lockfile integration is handled by SnakeBridge at compile time.

## Zero-Copy Interop

```elixir
config :snakepit, :zero_copy, [
  enabled: true,
  dlpack: true,
  arrow: true,
  allow_fallback: true,         # copy if zero-copy not supported
  max_bytes: 64 * 1024 * 1024,  # threshold for large payloads
  strict: false                 # raise if zero-copy fails
]
```

## Crash Barrier

```elixir
config :snakepit, :crash_barrier, [
  enabled: true,
  retry: :idempotent,           # :never | :idempotent | :always
  max_restarts: 3,
  taint_duration_ms: 60_000,
  backoff_ms: [50, 100, 200],
  mark_on: [:segfault, :oom, :gpu]
]
```

## Exception Translation

```elixir
config :snakepit, :exception_translation, [
  enabled: true,
  include_traceback: true,
  max_frames: 15,
  truncate_message: 8_000,
  redact_paths: true
]
```

## Telemetry Additions

```elixir
config :snakepit, :telemetry, [
  zero_copy: true,
  crash_barrier: true,
  exception_translation: true
]
```

## Per-Pool Overrides

Crash barrier and zero-copy can be overridden per pool:

```elixir
config :snakepit,
  pooling_enabled: true,
  pools: [
    %{
      name: :default,
      pool_size: 6,
      crash_barrier: [enabled: true],
      zero_copy: [enabled: true]
    },
    %{
      name: :safe,
      pool_size: 2,
      crash_barrier: [enabled: false],
      zero_copy: [enabled: false]
    }
  ]
```

## SnakeBridge Runtime Contract

SnakeBridge wrappers must send payloads that include `kwargs`, `call_type`,
and `idempotent`. This is not a config value, but it is required for the
crash barrier to behave correctly. See `05-runtime-contract-snakebridge.md`.

