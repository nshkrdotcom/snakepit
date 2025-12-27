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

  defp log(level, category, message, metadata) do
    if should_log?(level, category) do
      Logger.log(level, message, with_category(metadata, category))
    end
  end

  defp should_log_level?(level) do
    configured_level = Application.get_env(:snakepit, :log_level, @default_level)

    case configured_level do
      :none -> false
      :error -> level == :error
      :warning -> level in [:error, :warning]
      :info -> level in [:error, :warning, :info]
      :debug -> true
      _ -> level == :error
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
