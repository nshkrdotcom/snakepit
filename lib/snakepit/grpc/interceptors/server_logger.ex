defmodule Snakepit.GRPC.Interceptors.ServerLogger do
  @moduledoc false

  @behaviour GRPC.Server.Interceptor

  alias Snakepit.Logger, as: SLog
  require Logger

  @impl true
  def init(opts) do
    Keyword.validate!(opts, level: :info)
  end

  @impl true
  def call(req, stream, next, opts) do
    if logging_enabled?() do
      level = Keyword.fetch!(opts, :level)
      Logger.metadata(request_id: Logger.metadata()[:request_id] || stream.request_id)

      Logger.log(level, "Handled by #{inspect(stream.server)}.#{elem(stream.rpc, 0)}")

      start = System.monotonic_time()
      result = next.(req, stream)
      stop = System.monotonic_time()

      status = elem(result, 0)
      diff = System.convert_time_unit(stop - start, :native, :microsecond)

      Logger.log(level, "Response #{inspect(status)} in #{formatted_diff(diff)}")

      result
    else
      next.(req, stream)
    end
  end

  defp logging_enabled? do
    case Application.get_env(:snakepit, :grpc_request_logging, :auto) do
      true -> true
      false -> false
      :auto -> SLog.should_log?(:debug, :grpc)
      _ -> SLog.should_log?(:debug, :grpc)
    end
  end

  defp formatted_diff(diff) when diff > 1000 do
    [diff |> div(1000) |> Integer.to_string(), "ms"]
  end

  defp formatted_diff(diff), do: [Integer.to_string(diff), "us"]
end
