defmodule Snakepit.TelemetryMetrics do
  @moduledoc """
  Telemetry metric definitions and reporters for Snakepit.

  Metrics focus on heartbeat and worker lifecycle events. Reporters are opt-in
  via configuration under `:snakepit, :telemetry_metrics`.
  """

  import Telemetry.Metrics

  @type reporter_child_spec :: Supervisor.child_spec()

  @default_config %{
    prometheus: %{
      enabled: false,
      port: 9568,
      name: :snakepit_prometheus_metrics,
      protocol: :http
    }
  }

  @doc """
  Returns the metric definitions for Snakepit telemetry.
  """
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      counter("snakepit.heartbeat.pings",
        event_name: [:snakepit, :heartbeat, :ping_sent],
        measurement: :pings,
        tags: [:worker_id]
      ),
      counter("snakepit.heartbeat.pongs",
        event_name: [:snakepit, :heartbeat, :pong_received],
        measurement: :pongs,
        tags: [:worker_id]
      ),
      counter("snakepit.heartbeat.failures",
        event_name: [:snakepit, :heartbeat, :monitor_failure],
        measurement: :failures,
        tags: [:worker_id, :failure_reason]
      ),
      summary("snakepit.heartbeat.latency",
        event_name: [:snakepit, :heartbeat, :pong_received],
        measurement: :latency_ms,
        unit: :millisecond,
        tags: [:worker_id]
      ),
      last_value("snakepit.heartbeat.missed",
        event_name: [:snakepit, :heartbeat, :heartbeat_timeout],
        measurement: :missed,
        tags: [:worker_id]
      ),
      counter("snakepit.grpc.worker.executions",
        event_name: [:snakepit, :grpc_worker, :execute, :stop],
        measurement: :executions,
        tags: [:worker_id, :command]
      ),
      counter("snakepit.grpc.worker.errors",
        event_name: [:snakepit, :grpc_worker, :execute, :stop],
        measurement: :errors,
        tags: [:worker_id, :command, :error]
      ),
      summary("snakepit.grpc.worker.duration",
        event_name: [:snakepit, :grpc_worker, :execute, :stop],
        measurement: :duration_ms,
        unit: :millisecond,
        tags: [:worker_id, :command]
      )
    ]
  end

  @doc """
  Returns reporter child specs enabled via configuration.
  """
  @spec reporter_children() :: [reporter_child_spec()]
  def reporter_children do
    Enum.flat_map([prometheus_child_spec()], fn
      nil -> []
      spec -> [spec]
    end)
  end

  defp prometheus_child_spec do
    %{prometheus: prometheus_config} = load_config()

    if truthy?(prometheus_config[:enabled]) do
      TelemetryMetricsPrometheus.child_spec(
        Keyword.merge(
          [
            metrics: metrics(),
            port: fetch_integer(prometheus_config[:port], 9568),
            name: prometheus_config[:name] || :snakepit_prometheus_metrics,
            protocol: prometheus_config[:protocol] || :http
          ],
          prometheus_extra_options(prometheus_config)
        )
      )
    end
  end

  defp prometheus_extra_options(config) do
    opts = []

    opts =
      case config[:ip] do
        nil -> opts
        ip when is_tuple(ip) -> Keyword.put(opts, :plug_cowboy_opts, ip: ip)
        ip when is_binary(ip) -> Keyword.put(opts, :plug_cowboy_opts, ip: parse_ip(ip))
        _ -> opts
      end

    opts
  end

  defp parse_ip(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, tuple} -> tuple
      {:error, _reason} -> {0, 0, 0, 0}
    end
  end

  defp truthy?(value) when is_boolean(value), do: value

  defp truthy?(value) when is_binary(value) do
    normalized = String.downcase(String.trim(value))
    normalized in ["true", "1", "yes", "on"]
  end

  defp truthy?(value) when is_integer(value), do: value != 0
  defp truthy?(true), do: true
  defp truthy?(_), do: false

  defp fetch_integer(nil, default), do: default

  defp fetch_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> default
    end
  end

  defp fetch_integer(value, _default) when is_integer(value), do: value
  defp fetch_integer(_, default), do: default

  defp load_config do
    base_config =
      Application.get_env(:snakepit, :telemetry_metrics, %{})
      |> to_map()

    Map.merge(@default_config, base_config, fn
      _key, default_value, user_value when is_map(default_value) and is_map(user_value) ->
        Map.merge(default_value, user_value)

      _key, _default_value, user_value ->
        user_value
    end)
  end

  defp to_map(value) when is_map(value), do: value

  defp to_map(value) when is_list(value) do
    Enum.into(value, %{}, fn
      {key, val} when is_atom(key) -> {key, to_map(val)}
      {key, val} -> {String.to_atom(to_string(key)), to_map(val)}
    end)
  end

  defp to_map(other), do: other
end
