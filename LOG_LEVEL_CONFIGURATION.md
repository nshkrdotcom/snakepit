# Snakepit Log Level Configuration

Snakepit provides fine-grained control over its internal logging to keep your application output clean.

## Quick Start

```elixir
# In your config/config.exs or application code
config :snakepit, log_level: :error  # Only show errors (default)
```

## Available Log Levels

| Level | Description | When to Use |
|-------|-------------|-------------|
| `:debug` | Show all logs including detailed diagnostics | Development, troubleshooting |
| `:info` | Show informational messages | Development |
| `:warning` | Only show warnings and errors | Production, demos, clean output |
| `:error` | Only show errors (default) | Production (minimal logging) |
| `:none` | Suppress all Snakepit logs | When you want complete silence |

## Category Filtering (Debug/Info Only)

Category filters apply only to `:debug` and `:info`. Warnings and errors bypass
categories (unless `log_level: :none`).

```elixir
config :snakepit, log_level: :debug
config :snakepit, log_categories: [:grpc, :pool, :bridge]
```

Available categories:
`:lifecycle`, `:pool`, `:grpc`, `:bridge`, `:worker`, `:startup`, `:shutdown`, `:telemetry`, `:general`.

## Configuration Examples

### In Configuration Files

```elixir
# config/config.exs
config :snakepit,
  log_level: :error,  # Suppress info, debug, and warnings
  pooling_enabled: true,
  pool_config: %{pool_size: 4}
```

### In Scripts (Mix.install)

```elixir
# examples/my_script.exs
Application.put_env(:snakepit, :log_level, :error)
Application.put_env(:snakepit, :pooling_enabled, true)

Mix.install([{:snakepit, path: "."}])

# Your code here - no Snakepit info logs!
Snakepit.execute("ping", %{})
```

### Runtime Configuration

```elixir
# Change log level at runtime
Application.put_env(:snakepit, :log_level, :debug)  # Enable debug logs
Application.put_env(:snakepit, :log_level, :none)   # Silence everything
```

## What Gets Suppressed?

When you set `log_level: :error`, Snakepit will suppress:

- ✅ Pool initialization messages
- ✅ Worker startup notifications
- ✅ Process registration logs
- ✅ Thread limit configuration
- ✅ Session creation logs
- ✅ Tool registration messages
- ✅ Debug diagnostics
- ❌ Errors (still shown)

## Use Cases

### Production Deployment
```elixir
config :snakepit, log_level: :error
```
Keep logs clean while still seeing errors.

### Development
```elixir
config :snakepit, log_level: :info
```
See what Snakepit is doing without overwhelming detail.

### Debugging Issues
```elixir
config :snakepit, log_level: :debug
```
See everything for troubleshooting.

### Demos and Examples
```elixir
config :snakepit, log_level: :none
```
Complete silence - only your application output.

## Note

This only affects **Snakepit's internal logs**. It does not affect:
- Your application's logs
- Elixir's Logger configuration
- Python worker logs (controlled by `SNAKEPIT_LOG_LEVEL` and `snakepit_bridge.configure_logging()`)

When Snakepit spawns Python workers it sets `SNAKEPIT_LOG_LEVEL` automatically.
Standalone Python entrypoints should call `configure_logging()` early to opt in.

## Redaction helpers

- Use the logger redaction helper when logging payloads you cannot drop entirely. It summarises maps/lists by shape, truncates long keys, and reports binary lengths instead of contents.
- The bridge and session store already call into the helper for tool parameters and metadata, protecting API keys and large blobs from leaking into log files (`test/unit/logger/redaction_test.exs`).
- Feel free to reuse the helper in downstream adapters for consistent masking semantics.

## Example Output Comparison

### Before (`:info` level):
```
[info] 🧵 Set Python thread limits...
[info] 🚀 Starting Snakepit with pooling enabled (size: 2)
[debug] Created worker capacity ETS table...
[info] Reserved worker slot default_worker_1...
[info] ✅ Worker 1/2 ready: default_worker_1
...
Ping result: %{"message" => "pong"}
```

### After (`:error` level):
```
Ping result: %{"message" => "pong"}
```

Much cleaner!
