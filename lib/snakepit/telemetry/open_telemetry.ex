defmodule Snakepit.Telemetry.OpenTelemetry do
  @moduledoc """
  Bootstraps OpenTelemetry tracing and telemetry bridges for Snakepit.

  When enabled via `:snakepit, :opentelemetry` configuration this module ensures
  the OpenTelemetry runtime is started, exporters are configured, and telemetry
  events are mapped to spans and span events. Exporters remain opt-in; by default
  spans are created but not shipped anywhere.
  """

  require OpenTelemetry.Tracer, as: Tracer

  alias OpenTelemetry.Span
  alias OpentelemetryTelemetry, as: OTelBridge
  alias Snakepit.Logger, as: SLog

  @grpc_handler_id "snakepit-otel-grpc-worker"
  @heartbeat_handler_id "snakepit-otel-heartbeat"
  @log_category :telemetry

  @doc """
  Configures OpenTelemetry and attaches telemetry handlers when enabled.
  """
  @spec setup() :: :ok
  def setup do
    config = load_config()

    if config.enabled do
      configure_resource(config)

      case maybe_ensure_runtime(config) do
        :ok ->
          attach_grpc_handlers(config)
          attach_heartbeat_handlers(config)
          :ok

        {:error, reason} ->
          SLog.warning(
            @log_category,
            "OpenTelemetry runtime unavailable (#{inspect(reason)}); continuing without spans"
          )

          :ok
      end
    else
      detach(@grpc_handler_id)
      detach(@heartbeat_handler_id)
      :ok
    end
  end

  defp ensure_runtime(config) do
    with :ok <- start_app(:opentelemetry),
         :ok <- maybe_start_exporter_app(config) do
      configure_exporter(config.exporters)
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp start_app(app) do
    case Application.ensure_all_started(app) do
      {:ok, _apps} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_start_exporter_app(%{exporters: %{otlp: %{enabled: true}}}) do
    start_app(:opentelemetry_exporter)
  end

  defp maybe_start_exporter_app(_config), do: :ok

  defp configure_exporter(%{otlp: %{enabled: true} = otlp}) do
    opts = otlp_exporter_opts(otlp)
    :otel_batch_processor.set_exporter(:opentelemetry_exporter, opts)
    :ok
  end

  defp configure_exporter(%{console: %{enabled: true}}) do
    :otel_batch_processor.set_exporter(:otel_exporter_stdout, %{})
    :ok
  end

  defp configure_exporter(_), do: :ok

  defp otlp_exporter_opts(otlp) do
    endpoint =
      otlp
      |> Map.get(:endpoint, "http://localhost:4318")
      |> to_string()

    headers =
      otlp
      |> Map.get(:headers, [])
      |> Enum.map(fn
        {k, v} -> {to_string(k), to_string(v)}
        other -> other
      end)

    protocol =
      otlp
      |> Map.get(:protocol, :http_protobuf)
      |> normalize_protocol()

    opts = %{endpoints: [endpoint], protocol: protocol}

    if headers != [] do
      Map.put(opts, :headers, headers)
    else
      opts
    end
  end

  defp normalize_protocol(value) when value in [:http_protobuf, "http_protobuf"],
    do: :http_protobuf

  defp normalize_protocol(value) when value in [:grpc, "grpc"], do: :grpc
  defp normalize_protocol(_), do: :http_protobuf

  defp configure_resource(%{resource: resource}) when resource != %{} do
    Application.put_env(:opentelemetry, :resource, resource)
  end

  defp configure_resource(_), do: :ok

  defp attach_grpc_handlers(config) do
    detach(@grpc_handler_id)

    events = [
      [:snakepit, :grpc_worker, :execute, :start],
      [:snakepit, :grpc_worker, :execute, :stop],
      [:snakepit, :grpc_worker, :execute, :exception]
    ]

    handler_config = %{tracer_id: config.tracer_id, debug_pid: Map.get(config, :debug_pid)}

    case :telemetry.attach_many(
           @grpc_handler_id,
           events,
           &handle_grpc_worker_event/4,
           handler_config
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  rescue
    error ->
      SLog.error(
        @log_category,
        "Failed to attach OpenTelemetry handler for GRPC worker: #{Exception.message(error)}"
      )

      :ok
  end

  defp attach_heartbeat_handlers(config) do
    detach(@heartbeat_handler_id)

    heartbeat_events = [
      [:snakepit, :heartbeat, :ping_sent],
      [:snakepit, :heartbeat, :pong_received],
      [:snakepit, :heartbeat, :monitor_failure],
      [:snakepit, :heartbeat, :heartbeat_timeout]
    ]

    case :telemetry.attach_many(
           @heartbeat_handler_id,
           heartbeat_events,
           &handle_heartbeat_event/4,
           config
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  rescue
    error ->
      SLog.warning(
        @log_category,
        "Failed to attach heartbeat OpenTelemetry handler: #{Exception.message(error)}"
      )

      :ok
  end

  defp handle_grpc_worker_event(
         [:snakepit, :grpc_worker, :execute, :start],
         measurements,
         metadata,
         %{tracer_id: tracer_id} = handler_config
       ) do
    attributes = span_attributes(metadata)
    start_opts = %{start_time: measurements.monotonic_time, attributes: attributes, kind: :client}
    OTelBridge.start_telemetry_span(tracer_id, span_name(metadata), metadata, start_opts)
    debug(handler_config, {:grpc_execute_start, metadata})
    :ok
  rescue
    error ->
      SLog.debug(@log_category, "OpenTelemetry start handler failed: #{Exception.message(error)}")
      :ok
  end

  defp handle_grpc_worker_event(
         [:snakepit, :grpc_worker, :execute, :stop],
         measurements,
         metadata,
         %{tracer_id: tracer_id} = handler_config
       ) do
    ctx = OTelBridge.set_current_telemetry_span(tracer_id, metadata)
    duration_ms = Map.get(measurements, :duration_ms)

    Tracer.set_attributes(stop_attributes(measurements, metadata))
    maybe_set_status(ctx, metadata)

    if duration_ms do
      Tracer.add_event("snakepit.grpc.duration", duration: duration_ms)
    end

    OTelBridge.end_telemetry_span(tracer_id, metadata)
    debug(handler_config, {:grpc_execute_stop, metadata, measurements})
    :ok
  rescue
    error ->
      SLog.debug(@log_category, "OpenTelemetry stop handler failed: #{Exception.message(error)}")
      :ok
  end

  defp handle_grpc_worker_event(
         [:snakepit, :grpc_worker, :execute, :exception],
         measurements,
         metadata,
         %{tracer_id: tracer_id} = handler_config
       ) do
    ctx = OTelBridge.set_current_telemetry_span(tracer_id, metadata)

    kind = Map.get(metadata, :kind, :error)
    reason = Map.get(metadata, :reason, :unknown)
    stacktrace = Map.get(metadata, :stacktrace, [])
    _ = Map.get(measurements, :duration)

    Span.record_exception(ctx, kind, reason, stacktrace)
    Tracer.set_status(:error, format_reason(reason))
    OTelBridge.end_telemetry_span(tracer_id, metadata)
    debug(handler_config, {:grpc_execute_exception, metadata, measurements})
    :ok
  rescue
    error ->
      SLog.debug(
        @log_category,
        "OpenTelemetry exception handler failed: #{Exception.message(error)}"
      )

      :ok
  end

  defp handle_grpc_worker_event(_event, _measurements, _metadata, _config), do: :ok

  defp handle_heartbeat_event([:snakepit, :heartbeat, event], measurements, metadata, _config) do
    attributes = heartbeat_attributes(event, measurements, metadata)
    name = "snakepit.heartbeat.#{event}"

    case Tracer.current_span_ctx() do
      :undefined -> :ok
      _ctx -> Tracer.add_event(name, attributes)
    end
  rescue
    error ->
      SLog.debug(
        @log_category,
        "Heartbeat OpenTelemetry event failed: #{Exception.message(error)}"
      )

      :ok
  end

  defp span_name(metadata) do
    command = metadata[:command] || "execute"
    "snakepit.grpc.#{command}"
  end

  defp span_attributes(metadata) do
    [
      {"snakepit.worker.id", metadata[:worker_id]},
      {"snakepit.worker.pid", pid_attribute(metadata[:worker_pid])},
      {"snakepit.pool", pool_attribute(metadata[:pool])},
      {"snakepit.command", metadata[:command]},
      {"snakepit.session_id", metadata[:session_id]},
      {"snakepit.correlation_id", metadata[:correlation_id]},
      {"snakepit.telemetry.operation", metadata[:operation]}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp stop_attributes(measurements, metadata) do
    [
      {"snakepit.grpc.duration_ms", measurements[:duration_ms]},
      {"snakepit.grpc.status", metadata[:status]},
      {"snakepit.grpc.error", format_reason(metadata[:error])},
      {"snakepit.grpc.error_kind", metadata[:error_kind]},
      {"snakepit.grpc.executions", measurements[:executions]},
      {"snakepit.grpc.errors", measurements[:errors]}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp heartbeat_attributes(:pong_received, measurements, metadata) do
    [
      {"snakepit.worker.id", metadata[:worker_id]},
      {"snakepit.heartbeat.latency_ms", measurements[:latency_ms]},
      {"snakepit.heartbeat.missed", metadata[:missed_heartbeats]}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp heartbeat_attributes(:heartbeat_timeout, measurements, metadata) do
    [
      {"snakepit.worker.id", metadata[:worker_id]},
      {"snakepit.heartbeat.missed", measurements[:missed]},
      {"snakepit.heartbeat.timeouts", measurements[:timeouts]}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp heartbeat_attributes(:monitor_failure, _measurements, metadata) do
    [
      {"snakepit.worker.id", metadata[:worker_id]},
      {"snakepit.heartbeat.failure_reason", format_reason(metadata[:failure_reason])}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp heartbeat_attributes(:ping_sent, _measurements, metadata) do
    [
      {"snakepit.worker.id", metadata[:worker_id]}
    ]
  end

  defp heartbeat_attributes(_event, _measurements, metadata) do
    [
      {"snakepit.worker.id", metadata[:worker_id]}
    ]
  end

  defp maybe_set_status(ctx, %{status: :error, error: error}) do
    Span.set_status(ctx, OpenTelemetry.status(:error, format_reason(error)))
  end

  defp maybe_set_status(_ctx, _metadata), do: :ok

  defp pid_attribute(nil), do: nil
  defp pid_attribute(pid) when is_pid(pid), do: inspect(pid)
  defp pid_attribute(other), do: other

  defp pool_attribute(nil), do: nil
  defp pool_attribute(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp pool_attribute(other), do: inspect(other)

  defp format_reason(nil), do: nil
  defp format_reason({kind, reason}), do: "#{inspect(kind)}: #{inspect(reason)}"
  defp format_reason(reason), do: inspect(reason)

  defp detach(handler_id) do
    :telemetry.detach(handler_id)
  rescue
    _ -> :ok
  end

  defp maybe_ensure_runtime(%{skip_runtime?: true}), do: :ok
  defp maybe_ensure_runtime(config), do: ensure_runtime(config)

  defp load_config do
    defaults = %{
      enabled: false,
      tracer_id: :snakepit_grpc_worker,
      skip_runtime?: false,
      exporters: %{
        otlp: %{
          enabled: false,
          endpoint: "http://localhost:4318",
          protocol: :http_protobuf,
          headers: []
        },
        console: %{
          enabled: false
        }
      },
      resource: %{}
    }

    config =
      :snakepit
      |> Application.get_env(:opentelemetry, %{})
      |> to_map()
      |> deep_merge(defaults)
      |> Map.update!(:enabled, &truthy?/1)

    cond do
      Map.get(config, :force?, false) ->
        config

      Application.get_env(:snakepit, :enable_otlp?, false) ->
        config

      true ->
        Map.put(config, :enabled, false)
    end
  end

  defp to_map(value) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> {normalize_key(k), to_map(v)} end)
    |> Enum.into(%{})
  end

  defp to_map(list) when is_list(list) do
    if Keyword.keyword?(list) do
      list
      |> Enum.map(fn {k, v} -> {normalize_key(k), to_map(v)} end)
      |> Enum.into(%{})
    else
      Enum.map(list, &to_map/1)
    end
  end

  defp to_map(other), do: other

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: String.to_atom(key)
  defp normalize_key(other), do: other

  defp deep_merge(map, defaults) when is_map(map) and is_map(defaults) do
    Map.merge(defaults, map, fn _key, default_val, user_val ->
      deep_merge(user_val, default_val)
    end)
  end

  defp deep_merge(value, _default), do: value

  defp truthy?(value) when is_boolean(value), do: value

  defp truthy?(value) when is_binary(value) do
    normalized = String.downcase(String.trim(value))
    normalized in ["true", "1", "yes", "on"]
  end

  defp truthy?(value) when is_integer(value), do: value != 0
  defp truthy?(true), do: true
  defp truthy?(_), do: false

  defp debug(%{debug_pid: pid}, message) when is_pid(pid) do
    send(pid, {:snakepit_otel, message})
    :ok
  end

  defp debug(_config, _message), do: :ok
end
