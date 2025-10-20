# Snakepit Log Level Configuration

Snakepit provides fine-grained control over its internal logging to keep your application output clean.

## Quick Start

```elixir
# In your config/config.exs or application code
config :snakepit, log_level: :warning  # Only show warnings and errors
```

## Available Log Levels

| Level | Description | When to Use |
|-------|-------------|-------------|
| `:debug` | Show all logs including detailed diagnostics | Development, troubleshooting |
| `:info` | Show informational messages (default) | Development |
| `:warning` | Only show warnings and errors | Production, demos, clean output |
| `:error` | Only show errors | Production (minimal logging) |
| `:none` | Suppress all Snakepit logs | When you want complete silence |

## Configuration Examples

### In Configuration Files

```elixir
# config/config.exs
config :snakepit,
  log_level: :warning,  # Suppress info and debug logs
  pooling_enabled: true,
  pool_config: %{pool_size: 4}
```

### In Scripts (Mix.install)

```elixir
# examples/my_script.exs
Application.put_env(:snakepit, :log_level, :warning)
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

When you set `log_level: :warning`, Snakepit will suppress:

- ✅ Pool initialization messages
- ✅ Worker startup notifications
- ✅ Process registration logs
- ✅ Thread limit configuration
- ✅ Session creation logs
- ✅ Tool registration messages
- ✅ Debug diagnostics
- ❌ Warnings (still shown)
- ❌ Errors (still shown)

## Use Cases

### Production Deployment
```elixir
config :snakepit, log_level: :warning
```
Keep logs clean while still seeing important warnings and errors.

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
- Python worker output (configure separately with `PYTHONUNBUFFERED`)

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

### After (`:warning` level):
```
Ping result: %{"message" => "pong"}
```

Much cleaner!

## Development Log Fanout

For verbose development workflows you can mirror Python worker output to a dedicated log file.

```elixir
config :snakepit,
  dev_logfanout?: true,
  dev_log_path: "/var/log/snakepit/python-dev.log"
```

Set the `SNAKEPIT_VERBOSE=1` environment variable in development to enable the fanout automatically (see `config/dev.exs`). When enabled, every worker log line is prefixed with `[snakepit]` and appended to the configured path while still flowing through `Snakepit.Logger` with metadata (`worker_id`, `pool`, `python_pid`).

```bash
SNAKEPIT_VERBOSE=1 mix test
```
