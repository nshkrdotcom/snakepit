defmodule Snakepit.GRPCWorker.Instrumentation do
  @moduledoc false

  alias Snakepit.Telemetry.Correlation
  require OpenTelemetry.Tracer, as: Tracer

  def instrument_execute(kind, state, command, args, timeout, fun) when is_function(fun, 1) do
    correlation_id = correlation_id_from(args)
    metadata = base_execute_metadata(kind, state, command, args, correlation_id, timeout)
    span_name = otel_span_name(kind, command)
    span_attributes = otel_start_attributes(state, command, args, correlation_id, timeout)

    :telemetry.span([:snakepit, :grpc_worker, kind], metadata, fn ->
      Tracer.with_span span_name, %{attributes: span_attributes, kind: :client} do
        start_time = System.monotonic_time()
        result = fun.(args)

        duration_native = System.monotonic_time() - start_time
        duration_ms = System.convert_time_unit(duration_native, :native, :millisecond)

        measurements =
          %{duration_ms: duration_ms, executions: 1}
          |> maybe_track_error_measurement(result)

        stop_metadata = build_stop_metadata(metadata, result)

        Tracer.set_attributes(otel_stop_attributes(result, duration_ms, stop_metadata))
        maybe_set_span_status(result, stop_metadata)

        {result, measurements, stop_metadata}
      end
    end)
  end

  def emit_worker_spawned_telemetry(state, actual_port) do
    start_time = Map.get(state.stats, :start_time, System.monotonic_time())

    :telemetry.execute(
      [:snakepit, :pool, :worker, :spawned],
      %{
        duration: System.monotonic_time() - start_time,
        system_time: System.system_time()
      },
      %{
        node: node(),
        pool_name: state.pool_name,
        worker_id: state.id,
        worker_pid: self(),
        python_port: actual_port,
        python_pid: state.process_pid,
        mode: :process
      }
    )
  end

  def emit_worker_terminated_telemetry(state, reason, planned?) do
    start_time = Map.get(state.stats, :start_time, 0)
    total_commands = Map.get(state.stats, :requests, 0)

    :telemetry.execute(
      [:snakepit, :pool, :worker, :terminated],
      %{
        lifetime: System.monotonic_time() - start_time,
        total_commands: total_commands
      },
      %{
        node: node(),
        pool_name: state.pool_name,
        worker_id: state.id,
        worker_pid: self(),
        reason: reason,
        planned: planned?
      }
    )
  end

  def ensure_correlation(nil) do
    id = Correlation.new_id()
    %{"correlation_id" => id, correlation_id: id}
  end

  def ensure_correlation(args) when is_map(args) do
    existing =
      Map.get(args, :correlation_id) ||
        Map.get(args, "correlation_id")

    id = Correlation.ensure(existing)

    args
    |> Map.put(:correlation_id, id)
    |> Map.put("correlation_id", id)
  end

  def ensure_correlation(args) when is_list(args) do
    args
    |> Map.new()
    |> ensure_correlation()
  end

  defp correlation_id_from(%{} = args) do
    args
    |> Map.get(:correlation_id)
    |> case do
      nil -> Map.get(args, "correlation_id")
      value -> value
    end
    |> Correlation.ensure()
  end

  defp base_execute_metadata(kind, state, command, args, correlation_id, timeout) do
    session_id =
      Map.get(args, :session_id) ||
        Map.get(args, "session_id") ||
        state.session_id

    %{
      operation: kind,
      worker_id: state.id,
      worker_pid: self(),
      command: command,
      adapter: adapter_name(state.adapter),
      adapter_module: state.adapter,
      pool: state.pool_name,
      session_id: session_id,
      correlation_id: correlation_id,
      timeout_ms: timeout,
      span_kind: :client,
      rpc_system: :grpc,
      telemetry_source: :snakepit_grpc_worker
    }
  end

  defp otel_span_name(kind, command) do
    operation = kind |> Atom.to_string() |> String.replace("_", "-")
    "snakepit.grpc.#{operation}.#{command}"
  end

  defp otel_start_attributes(state, command, args, correlation_id, timeout) do
    session_id = Map.get(args, :session_id) || Map.get(args, "session_id") || state.session_id

    [
      {"snakepit.worker.id", state.id},
      {"snakepit.pool", pool_attribute(state.pool_name)},
      {"snakepit.command", command},
      {"snakepit.session_id", session_id},
      {"snakepit.correlation_id", correlation_id},
      {"snakepit.timeout_ms", timeout}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp otel_stop_attributes(result, duration_ms, metadata) do
    [
      {"snakepit.grpc.duration_ms", duration_ms},
      {"snakepit.grpc.status", metadata[:status]},
      {"snakepit.grpc.error", format_reason(metadata[:error] || error_from_result(result))},
      {"snakepit.grpc.error_kind", metadata[:error_kind]}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp maybe_set_span_status({:error, _}, metadata) do
    reason = format_reason(metadata[:error]) || "snakepit.grpc.error"
    Tracer.set_status(:error, reason)
  end

  defp maybe_set_span_status(_result, _metadata), do: :ok

  defp build_stop_metadata(metadata, {:error, {kind, reason}}) do
    metadata
    |> Map.put(:status, :error)
    |> Map.put(:error_kind, kind)
    |> Map.put(:error, reason)
  end

  defp build_stop_metadata(metadata, {:error, reason}) do
    metadata
    |> Map.put(:status, :error)
    |> Map.put(:error, reason)
  end

  defp build_stop_metadata(metadata, _result) do
    Map.put(metadata, :status, :ok)
  end

  defp maybe_track_error_measurement(measurements, {:error, _reason}) do
    Map.put(measurements, :errors, 1)
  end

  defp maybe_track_error_measurement(measurements, _result), do: measurements

  defp pool_attribute(nil), do: nil
  defp pool_attribute(pool) when is_atom(pool), do: Atom.to_string(pool)
  defp pool_attribute(pool), do: inspect(pool)

  defp format_reason(nil), do: nil
  defp format_reason({kind, reason}), do: "#{inspect(kind)}: #{inspect(reason)}"
  defp format_reason(reason), do: inspect(reason)

  defp error_from_result({:error, {kind, reason}}), do: {kind, reason}
  defp error_from_result({:error, reason}), do: reason
  defp error_from_result(_), do: nil

  defp adapter_name(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
  end

  defp adapter_name(other), do: inspect(other)
end
