defmodule Snakepit.Logger do
  @moduledoc """
  Centralized, silent-by-default logging for Snakepit.

  ## Configuration

      # Silent (default) - only errors
      config :snakepit, log_level: :error

      # Warnings and errors
      config :snakepit, log_level: :warning

      # Verbose - info, warnings, errors
      config :snakepit, log_level: :info

      # Debug - everything
      config :snakepit, log_level: :debug

      # Completely silent (not even errors)
      config :snakepit, log_level: :none

  ## Categories

  Enable specific categories for targeted debugging:

      config :snakepit, log_categories: [:lifecycle, :grpc]

  ## Process-Level Isolation (for Testing)

  Log levels can be set per-process to avoid race conditions in async tests:

      # Set log level for current process only
      Snakepit.Logger.set_process_level(:debug)

      # Execute with temporary log level
      Snakepit.Logger.with_level(:warning, fn ->
        # ... code that should log at warning level
      end)

      # Clear process-level override
      Snakepit.Logger.clear_process_level()

  The resolution order is:
  1. Process-level override (via `set_process_level/1`)
  2. Elixir Logger process level (via `Logger.put_process_level/2`)
  3. Application config (via `config :snakepit, log_level: ...`)
  """

  require Logger

  @type category ::
          :lifecycle
          | :pool
          | :grpc
          | :bridge
          | :worker
          | :startup
          | :shutdown
          | :telemetry
          | :general
  @type level :: :debug | :info | :warning | :error | :none

  @default_level :error
  @default_category :general
  @process_level_key :snakepit_log_level_override
  @category_whitelist [
    :lifecycle,
    :pool,
    :grpc,
    :bridge,
    :worker,
    :startup,
    :shutdown,
    :telemetry,
    :general
  ]

  @doc """
  Log at debug level if configured log level allows it.
  """
  def debug(category, message, metadata) when category in @category_whitelist do
    log(:debug, category, message, metadata)
  end

  def debug(category, message) when category in @category_whitelist do
    log(:debug, category, message, [])
  end

  def debug(message, metadata), do: log(:debug, @default_category, message, metadata)
  def debug(message), do: log(:debug, @default_category, message, [])

  @doc """
  Log at info level if configured log level allows it.
  """
  def info(category, message, metadata) when category in @category_whitelist do
    log(:info, category, message, metadata)
  end

  def info(category, message) when category in @category_whitelist do
    log(:info, category, message, [])
  end

  def info(message, metadata), do: log(:info, @default_category, message, metadata)
  def info(message), do: log(:info, @default_category, message, [])

  @doc """
  Log at warning level if configured log level allows it.
  """
  def warning(category, message, metadata) when category in @category_whitelist do
    log(:warning, category, message, metadata)
  end

  def warning(category, message) when category in @category_whitelist do
    log(:warning, category, message, [])
  end

  def warning(message, metadata), do: log(:warning, @default_category, message, metadata)
  def warning(message), do: log(:warning, @default_category, message, [])

  @doc """
  Log at error level if configured log level allows it.
  """
  def error(category, message, metadata) when category in @category_whitelist do
    log(:error, category, message, metadata)
  end

  def error(category, message) when category in @category_whitelist do
    log(:error, category, message, [])
  end

  def error(message, metadata), do: log(:error, @default_category, message, metadata)
  def error(message), do: log(:error, @default_category, message, [])

  @doc """
  Check if logging at the given level is enabled.
  """
  def should_log?(level), do: should_log_level?(level)

  @doc """
  Check if logging at the given level/category is enabled.
  """
  def should_log?(level, category) do
    should_log_level?(level) and category_allowed?(level, category)
  end

  @doc """
  Set the log level for the current process only.

  This is useful for test isolation - each test process can have its own
  log level without affecting other concurrent tests.

  ## Examples

      Snakepit.Logger.set_process_level(:debug)
      # All logging in this process now uses :debug level

      Snakepit.Logger.set_process_level(:none)
      # All logging in this process is now suppressed

  """
  @spec set_process_level(level()) :: :ok
  def set_process_level(level) when level in [:debug, :info, :warning, :error, :none] do
    Process.put(@process_level_key, level)
    :ok
  end

  @doc """
  Get the effective log level for the current process.

  Returns the log level in priority order:
  1. Process-level override (set via `set_process_level/1`)
  2. Elixir Logger process level
  3. Application config
  """
  @spec get_process_level() :: level()
  def get_process_level do
    resolve_effective_level()
  end

  @doc """
  Clear the process-level log level override.

  After calling this, the process will use the global Application config.
  """
  @spec clear_process_level() :: :ok
  def clear_process_level do
    Process.delete(@process_level_key)
    :ok
  end

  @doc """
  Execute a function with a temporary log level for the current process.

  The previous log level is restored after the function completes,
  even if it raises an exception.

  ## Examples

      Snakepit.Logger.with_level(:debug, fn ->
        # Debug logs are enabled here
        Snakepit.Logger.debug(:pool, "detailed info")
      end)
      # Previous log level is restored

  """
  @spec with_level(level(), (-> result)) :: result when result: term()
  def with_level(level, fun) when is_function(fun, 0) do
    previous = Process.get(@process_level_key)

    try do
      set_process_level(level)
      fun.()
    after
      if previous do
        Process.put(@process_level_key, previous)
      else
        Process.delete(@process_level_key)
      end
    end
  end

  defp log(level, category, message, metadata) do
    if should_log?(level, category) do
      Logger.log(level, message, with_category(metadata, category))
    end
  end

  defp should_log_level?(level) do
    effective_level = resolve_effective_level()

    case effective_level do
      :none -> false
      :error -> level == :error
      :warning -> level in [:error, :warning]
      :info -> level in [:error, :warning, :info]
      :debug -> true
      _ -> level == :error
    end
  end

  # Resolve the effective log level using priority order:
  # 1. Process-level override (highest priority)
  # 2. Elixir Logger process level
  # 3. Application config (lowest priority)
  defp resolve_effective_level do
    case Process.get(@process_level_key) do
      nil ->
        case Logger.get_process_level(self()) do
          nil ->
            Application.get_env(:snakepit, :log_level, @default_level)

          # Map Elixir Logger levels to our levels
          logger_level when logger_level in [:emergency, :alert, :critical, :error] ->
            :error

          :warning ->
            :warning

          :notice ->
            :warning

          :info ->
            :info

          :debug ->
            :debug

          :all ->
            :debug

          :none ->
            :none

          _ ->
            Application.get_env(:snakepit, :log_level, @default_level)
        end

      level ->
        level
    end
  end

  defp category_allowed?(level, category) when level in [:debug, :info] do
    case Application.get_env(:snakepit, :log_categories) do
      nil -> true
      categories when is_list(categories) -> category in categories
      _ -> true
    end
  end

  defp category_allowed?(_level, _category), do: true

  defp with_category(metadata, category) do
    metadata
    |> normalize_metadata()
    |> Keyword.put_new(:category, category)
  end

  defp normalize_metadata(metadata) when is_list(metadata), do: metadata
  defp normalize_metadata(metadata) when is_map(metadata), do: Map.to_list(metadata)
  defp normalize_metadata(_metadata), do: []
end
