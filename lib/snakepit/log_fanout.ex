defmodule Snakepit.LogFanout do
  @moduledoc """
  Development-only fanout that mirrors Python worker output to a shared log file.

  When `config :snakepit, :dev_logfanout?` is enabled, each line received from a
  worker is appended to `:dev_log_path` (defaults to `/var/log/snakepit/python-dev.log`)
  with a `[snakepit]` prefix and worker metadata. The message is always passed
  through to `Snakepit.Logger` so existing logging behaviour is preserved.
  """

  alias Snakepit.Logger, as: SLog

  @default_log_path "/var/log/snakepit/python-dev.log"

  @doc """
  Handle a worker log line and optional metadata.
  """
  @spec handle_log(String.t(), map() | keyword()) :: :ok
  def handle_log(message, metadata \\ %{})

  def handle_log(message, metadata) when is_binary(message) do
    metadata_map = normalize_metadata(metadata)

    SLog.info(message, Map.to_list(metadata_map))

    if Application.get_env(:snakepit, :dev_logfanout?, false) do
      formatted = format_line(message, metadata_map)
      persist(formatted)
    end

    :ok
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata

  defp normalize_metadata(metadata) when is_list(metadata), do: Map.new(metadata)

  defp normalize_metadata(_), do: %{}

  defp format_line(message, metadata) do
    meta_string =
      metadata
      |> Enum.map(fn {key, value} -> "#{key}=#{value}" end)
      |> Enum.join(" ")

    case meta_string do
      "" -> "[snakepit] #{message}"
      _ -> "[snakepit] #{meta_string} #{message}"
    end
  end

  defp persist(line) do
    log_path = Application.get_env(:snakepit, :dev_log_path, @default_log_path)
    log_dir = Path.dirname(log_path)

    with :ok <- File.mkdir_p(log_dir) do
      case :file.write_file(log_path, line <> "\n", [:append]) do
        :ok ->
          :ok

        {:error, reason} ->
          SLog.error("Failed to append Snakepit log fanout to #{log_path}: #{inspect(reason)}")
          :error
      end
    else
      {:error, reason} ->
        SLog.error("Failed to prepare Snakepit log directory #{log_dir}: #{inspect(reason)}")
        :error
    end
  end
end
