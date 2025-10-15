defmodule Snakepit.Logger do
  @moduledoc """
  Centralized logging for Snakepit with configurable verbosity.

  Users can control Snakepit's log output with:

      config :snakepit, log_level: :warning  # Only show warnings and errors
      config :snakepit, log_level: :info     # Show info, warnings, and errors (default)
      config :snakepit, log_level: :debug    # Show everything
      config :snakepit, log_level: :none     # Suppress all Snakepit logs
  """

  require Logger

  @doc """
  Log at debug level if configured log level allows it.
  """
  def debug(message, metadata \\ []) do
    if should_log?(:debug) do
      Logger.debug(message, metadata)
    end
  end

  @doc """
  Log at info level if configured log level allows it.
  """
  def info(message, metadata \\ []) do
    if should_log?(:info) do
      Logger.info(message, metadata)
    end
  end

  @doc """
  Log at warning level if configured log level allows it.
  """
  def warning(message, metadata \\ []) do
    if should_log?(:warning) do
      Logger.warning(message, metadata)
    end
  end

  @doc """
  Log at error level if configured log level allows it.
  """
  def error(message, metadata \\ []) do
    if should_log?(:error) do
      Logger.error(message, metadata)
    end
  end

  @doc """
  Check if logging at the given level is enabled.
  """
  def should_log?(level) do
    configured_level = Application.get_env(:snakepit, :log_level, :info)

    case configured_level do
      :none -> false
      :error -> level == :error
      :warning -> level in [:error, :warning]
      :info -> level in [:error, :warning, :info]
      :debug -> true
      _ -> level in [:error, :warning, :info]  # Default to :info
    end
  end
end
