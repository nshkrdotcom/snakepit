defmodule Snakepit.Telemetry.GrpcStream do
  @moduledoc """
  Manages gRPC telemetry streams from Python workers.

  This GenServer maintains bidirectional telemetry streams with Python workers,
  translating Python telemetry events into Elixir `:telemetry` events.

  Features:
  - Automatic stream registration when workers connect
  - Dynamic sampling rate adjustments
  - Event filtering
  - Graceful handling of worker disconnections
  """

  use GenServer
  alias Snakepit.Config
  alias Snakepit.Logger, as: SLog

  alias GRPC.Channel
  alias Snakepit.Bridge.{BridgeService, TelemetryEvent}
  alias Snakepit.Telemetry.{Control, Naming, SafeMetadata}
  @log_category :telemetry

  @type worker_ctx :: %{
          worker_id: String.t(),
          pool_name: atom(),
          python_pid: integer() | nil
        }

  ## Client API

  @doc """
  Starts the telemetry stream manager.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a worker for telemetry streaming.

  Automatically initiates a telemetry stream with the worker and starts
  consuming events.

  ## Examples

      iex> channel = connect_to_worker()
      iex> Snakepit.Telemetry.GrpcStream.register_worker(channel, %{
      ...>   worker_id: "worker_1",
      ...>   pool_name: :default,
      ...>   python_pid: 12345
      ...> })
      :ok
  """
  def register_worker(channel, worker_ctx) do
    if stream_capable_channel?(channel) do
      GenServer.cast(__MODULE__, {:register_worker, channel, worker_ctx})
    else
      SLog.debug(
        @log_category,
        "Skipping telemetry stream registration; channel unsupported",
        worker_id: worker_ctx.worker_id,
        pool_name: worker_ctx.pool_name,
        channel_type: describe_channel(channel)
      )

      :ok
    end
  end

  @doc """
  Removes a worker from telemetry streaming.

  Called when a worker disconnects or terminates.
  """
  def unregister_worker(worker_id) do
    GenServer.cast(__MODULE__, {:unregister_worker, worker_id})
  end

  @doc """
  Updates the sampling rate for a specific worker.

  ## Examples

      iex> Snakepit.Telemetry.GrpcStream.update_sampling("worker_1", 0.1)
      :ok

      iex> Snakepit.Telemetry.GrpcStream.update_sampling("worker_1", 0.5, ["python.call.*"])
      :ok
  """
  def update_sampling(worker_id, rate, patterns \\ []) do
    GenServer.cast(__MODULE__, {:update_sampling, worker_id, rate, patterns})
  end

  @doc """
  Enables or disables telemetry for a specific worker.
  """
  def toggle(worker_id, enabled) do
    GenServer.cast(__MODULE__, {:toggle, worker_id, enabled})
  end

  @doc """
  Updates event filters for a specific worker.
  """
  def update_filter(worker_id, opts) do
    GenServer.cast(__MODULE__, {:update_filter, worker_id, opts})
  end

  @doc """
  Gets the current state of all registered streams.
  """
  def list_streams do
    list_streams(fn -> GenServer.call(__MODULE__, :list_streams) end)
  end

  @doc false
  def list_streams(call_fun) when is_function(call_fun, 0) do
    try do
      call_fun.()
    catch
      :exit, {:noproc, _} -> []
      :exit, :noproc -> []
    end
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{streams: %{}, ops: %{}}}
  end

  @impl true
  def handle_cast({:register_worker, channel, worker_ctx}, state) do
    worker_id = worker_ctx.worker_id

    new_state =
      state
      |> drop_worker(worker_id)
      |> start_stream_task(worker_id, channel, worker_ctx)

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:unregister_worker, worker_id}, state) do
    {:noreply, drop_worker(state, worker_id)}
  end

  @impl true
  def handle_cast({:update_sampling, worker_id, rate, patterns}, state) do
    control_msg = Control.sampling(rate, patterns)
    metadata = %{action: :sampling, rate: rate, patterns: patterns}
    {:noreply, enqueue_control_message(state, worker_id, control_msg, metadata)}
  end

  @impl true
  def handle_cast({:toggle, worker_id, enabled}, state) do
    control_msg = Control.toggle(enabled)
    metadata = %{action: :toggle, enabled: enabled}
    {:noreply, enqueue_control_message(state, worker_id, control_msg, metadata)}
  end

  @impl true
  def handle_cast({:update_filter, worker_id, opts}, state) do
    control_msg = Control.filter(opts)
    metadata = %{action: :filter}
    {:noreply, enqueue_control_message(state, worker_id, control_msg, metadata)}
  end

  @impl true
  def handle_call(:list_streams, _from, state) do
    stream_info =
      Enum.map(state.streams, fn {worker_id, info} ->
        %{
          worker_id: worker_id,
          pool_name: info.worker_ctx.pool_name,
          task_alive: info.task && Process.alive?(info.task.pid)
        }
      end)

    {:reply, stream_info, state}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case pop_op(state, ref) do
      {:ok, op, state_without_op} ->
        Process.demonitor(ref, [:flush])
        {:noreply, handle_stream_op_result(op, result, state_without_op)}

      :error ->
        case pop_stream_by_ref(state, ref) do
          {:ok, worker_id, new_state} ->
            Process.demonitor(ref, [:flush])

            SLog.debug(
              @log_category,
              "Telemetry stream task completed for worker #{worker_id}: #{inspect(result)}",
              worker_id: worker_id
            )

            {:noreply, new_state}

          :error ->
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case pop_op(state, ref) do
      {:ok, op, state_without_op} ->
        {:noreply, handle_stream_op_down(op, reason, state_without_op)}

      :error ->
        case pop_stream_by_ref(state, ref) do
          {:ok, worker_id, new_state} ->
            log_task_exit(worker_id, reason)
            {:noreply, new_state}

          :error ->
            case pop_stream_by_pid(state, pid) do
              {:ok, worker_id, new_state} ->
                log_task_exit(worker_id, reason)
                {:noreply, new_state}

              :error ->
                {:noreply, state}
            end
        end
    end
  end

  @impl true
  def handle_info({:stream_op_timeout, ref}, state) when is_reference(ref) do
    case pop_op(state, ref) do
      {:ok, op, state_without_op} ->
        Process.demonitor(ref, [:flush])

        if is_pid(op.task_pid) and Process.alive?(op.task_pid) do
          Process.exit(op.task_pid, :kill)
        end

        {:noreply, handle_stream_op_timeout(op, state_without_op)}

      :error ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:stream_ready, worker_id, stream_ref, result}, state)
      when is_reference(stream_ref) do
    case get_in(state, [:streams, worker_id]) do
      %{stream_ref: ^stream_ref} = stream_info ->
        stream_info = cancel_stream_open_timer(stream_info)

        case result do
          {:ok, stream} ->
            worker_ctx = stream_info.worker_ctx

            next_state =
              state
              |> put_in([:streams, worker_id], %{
                stream_info
                | stream: stream,
                  connecting?: false,
                  started_at: System.monotonic_time()
              })
              |> start_next_control_op(worker_id)

            SLog.info(
              @log_category,
              "Telemetry stream registered for worker #{worker_id}",
              worker_id: worker_id,
              pool_name: worker_ctx.pool_name
            )

            {:noreply, next_state}

          {:error, reason} ->
            SLog.warning(
              @log_category,
              "Failed to register telemetry stream for worker #{worker_id}: #{inspect(reason)}",
              worker_id: worker_id,
              reason: reason
            )

            {:noreply, drop_worker(put_in(state, [:streams, worker_id], stream_info), worker_id)}
        end

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:stream_open_timeout, worker_id, stream_ref}, state)
      when is_reference(stream_ref) do
    case get_in(state, [:streams, worker_id]) do
      %{stream_ref: ^stream_ref} = stream_info ->
        if is_pid(stream_info.task && stream_info.task.pid) and
             Process.alive?(stream_info.task.pid) do
          Process.exit(stream_info.task.pid, :kill)
        end

        SLog.warning(
          @log_category,
          "Timed out opening telemetry stream for worker #{worker_id}",
          worker_id: worker_id
        )

        {:noreply, drop_worker(state, worker_id)}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, state) do
    case pop_stream_by_pid(state, pid) do
      {:ok, worker_id, new_state} ->
        log_task_exit(worker_id, reason)
        {:noreply, new_state}

      :error ->
        if shutdown_exit?(reason) do
          {:stop, reason, state}
        else
          {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({:gun_response, _pid, _stream_ref, _fin, status, headers}, state) do
    SLog.debug(@log_category, "Telemetry stream HTTP response received",
      status: status,
      headers: headers
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({:gun_data, _pid, _stream_ref, _is_fin, _data}, state) do
    # gRPC data frames are consumed by GRPC.Stub.recv/2; ignore low-level messages.
    {:noreply, state}
  end

  @impl true
  def handle_info({:gun_down, _pid, _proto, _reason, _killed_streams, _}, state) do
    SLog.debug(@log_category, "Telemetry stream HTTP connection closed by gun")
    {:noreply, state}
  end

  @impl true
  def handle_info({:gun_error, _pid, _stream_ref, reason}, state) do
    SLog.debug(@log_category, "Telemetry stream HTTP error from gun", reason: reason)
    {:noreply, state}
  end

  @impl true
  def handle_info(_message, state) do
    {:noreply, state}
  end

  ## Private Helpers

  defp drop_worker(state, worker_id) do
    state =
      Enum.reduce(state.ops, state, fn
        {ref, %{worker_id: ^worker_id}}, acc ->
          case pop_op(acc, ref) do
            {:ok, op, acc_without_op} ->
              Process.demonitor(ref, [:flush])

              if is_pid(op.task_pid) and Process.alive?(op.task_pid) do
                Process.exit(op.task_pid, :kill)
              end

              acc_without_op

            :error ->
              acc
          end

        _, acc ->
          acc
      end)

    case Map.get(state.streams, worker_id) do
      nil ->
        state

      stream_info ->
        if is_reference(stream_info[:open_timer_ref]) do
          Process.cancel_timer(stream_info.open_timer_ref)
        end

        if stream_info.task && Process.alive?(stream_info.task.pid) do
          Task.shutdown(stream_info.task, :brutal_kill)
        end

        if stream_info.task do
          Process.demonitor(stream_info.task.ref, [:flush])
        end

        update_in(state, [:streams], &Map.delete(&1, worker_id))
    end
  end

  defp start_stream_task(state, worker_id, channel, worker_ctx) do
    stream_ref = make_ref()
    manager = self()

    task =
      Task.Supervisor.async_nolink(Snakepit.TaskSupervisor, fn ->
        result = initiate_stream(channel, worker_ctx)
        send(manager, {:stream_ready, worker_id, stream_ref, result})

        case result do
          {:ok, stream} ->
            consume_stream(stream, worker_ctx)

          {:error, _reason} ->
            :ok
        end
      end)

    stream_info = %{
      stream: nil,
      task: task,
      worker_ctx: worker_ctx,
      started_at: System.monotonic_time(),
      connecting?: true,
      pending_controls: [],
      control_ref: nil,
      stream_ref: stream_ref,
      open_timer_ref:
        Process.send_after(
          self(),
          {:stream_open_timeout, worker_id, stream_ref},
          Config.grpc_stream_open_timeout_ms()
        )
    }

    put_in(state, [:streams, worker_id], stream_info)
  end

  defp enqueue_control_message(state, worker_id, control_msg, metadata) do
    case Map.get(state.streams, worker_id) do
      nil ->
        SLog.debug(
          @log_category,
          "Cannot send telemetry control message for unknown worker #{worker_id}",
          worker_id: worker_id
        )

        state

      stream_info ->
        updated =
          Map.update(stream_info, :pending_controls, [{control_msg, metadata}], fn pending ->
            pending ++ [{control_msg, metadata}]
          end)

        state
        |> put_in([:streams, worker_id], updated)
        |> start_next_control_op(worker_id)
    end
  end

  defp start_next_control_op(state, worker_id) do
    case get_in(state, [:streams, worker_id]) do
      %{stream: nil} ->
        state

      %{control_ref: ref} when is_reference(ref) ->
        state

      %{pending_controls: []} ->
        state

      %{stream: stream, pending_controls: [{control_msg, metadata} | rest]} = stream_info ->
        task =
          Task.Supervisor.async_nolink(Snakepit.TaskSupervisor, fn ->
            send_control_request(stream, control_msg)
          end)

        op = %{
          kind: :control,
          worker_id: worker_id,
          metadata: metadata,
          task_pid: task.pid,
          timer_ref:
            Process.send_after(
              self(),
              {:stream_op_timeout, task.ref},
              Config.grpc_stream_control_timeout_ms()
            )
        }

        state
        |> put_in([:streams, worker_id], %{
          stream_info
          | pending_controls: rest,
            control_ref: task.ref
        })
        |> put_in([:ops, task.ref], op)
    end
  end

  defp pop_op(state, ref) do
    case Map.pop(state.ops, ref) do
      {nil, _ops} ->
        :error

      {op, ops} ->
        if op.timer_ref do
          Process.cancel_timer(op.timer_ref)
        end

        {:ok, op, %{state | ops: ops}}
    end
  end

  defp handle_stream_op_result(
         %{kind: :control, worker_id: worker_id, metadata: metadata},
         result,
         state
       ) do
    case Map.get(state.streams, worker_id) do
      nil ->
        state

      stream_info ->
        next_state =
          case result do
            {:ok, updated_stream} ->
              log_control_success(worker_id, metadata)
              put_in(state, [:streams, worker_id, :stream], updated_stream)

            {:error, reason} ->
              log_control_failure(worker_id, metadata, reason)
              state
          end

        next_state
        |> put_in([:streams, worker_id], %{stream_info | control_ref: nil})
        |> start_next_control_op(worker_id)
    end
  end

  defp handle_stream_op_down(%{kind: :control, worker_id: worker_id}, reason, state) do
    if reason not in [:normal, :shutdown] do
      SLog.warning(
        @log_category,
        "Telemetry control task exited for worker #{worker_id}",
        worker_id: worker_id,
        reason: reason
      )
    end

    case Map.get(state.streams, worker_id) do
      nil ->
        state

      stream_info ->
        state
        |> put_in([:streams, worker_id], %{stream_info | control_ref: nil})
        |> start_next_control_op(worker_id)
    end
  end

  defp handle_stream_op_timeout(
         %{kind: :control, worker_id: worker_id, metadata: metadata},
         state
       ) do
    SLog.warning(
      @log_category,
      "Timed out sending telemetry control message for worker #{worker_id}",
      worker_id: worker_id,
      action: metadata.action
    )

    case Map.get(state.streams, worker_id) do
      nil ->
        state

      stream_info ->
        state
        |> put_in([:streams, worker_id], %{stream_info | control_ref: nil})
        |> start_next_control_op(worker_id)
    end
  end

  defp log_control_success(worker_id, %{action: :sampling, rate: rate, patterns: patterns}) do
    SLog.debug(@log_category, "Updated sampling for worker #{worker_id} to #{rate}",
      worker_id: worker_id,
      rate: rate,
      patterns: patterns
    )
  end

  defp log_control_success(worker_id, %{action: :toggle, enabled: enabled}) do
    SLog.debug(@log_category, "Toggled telemetry for worker #{worker_id} to #{enabled}",
      worker_id: worker_id,
      enabled: enabled
    )
  end

  defp log_control_success(worker_id, %{action: :filter}) do
    SLog.debug(@log_category, "Updated filters for worker #{worker_id}", worker_id: worker_id)
  end

  defp log_control_success(_worker_id, _metadata), do: :ok

  defp log_control_failure(worker_id, metadata, reason) do
    SLog.warning(
      @log_category,
      "Failed to send telemetry control message for worker #{worker_id}: #{inspect(reason)}",
      worker_id: worker_id,
      reason: reason,
      action: Map.get(metadata, :action)
    )
  end

  defp send_control_request(stream, control_msg) do
    {:ok, GRPC.Stub.send_request(stream, control_msg)}
  rescue
    error ->
      {:error, error}
  catch
    :exit, reason ->
      {:error, reason}
  end

  defp initiate_stream(channel, _worker_ctx) do
    case channel |> open_telemetry_stream() |> normalize_stream_response() do
      {:ok, stream} ->
        # Send initial toggle message to enable telemetry
        stream = GRPC.Stub.send_request(stream, Control.toggle(true))
        {:ok, stream}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp open_telemetry_stream(channel) do
    BridgeService.Stub.stream_telemetry(channel, timeout: Config.grpc_stream_open_timeout_ms())
  rescue
    exception ->
      {:error, {:invalid_channel, exception}}
  end

  defp normalize_stream_response({:ok, %GRPC.Client.Stream{} = stream}), do: {:ok, stream}
  defp normalize_stream_response(%GRPC.Client.Stream{} = stream), do: {:ok, stream}
  defp normalize_stream_response({:error, _reason} = error), do: error
  defp normalize_stream_response(other), do: {:error, {:unexpected_stream_response, other}}

  defp consume_stream(stream, worker_ctx) do
    case GRPC.Stub.recv(stream, timeout: :infinity) do
      {:ok, enum} ->
        Enum.each(enum, fn
          {:ok, %TelemetryEvent{} = event} ->
            translate_and_emit(event, worker_ctx)

          %TelemetryEvent{} = event ->
            # Defensive compatibility: some adapters may yield decoded events directly.
            translate_and_emit(event, worker_ctx)

          {:ok, other} ->
            SLog.warning(
              @log_category,
              "Unexpected telemetry stream payload for worker #{worker_ctx.worker_id}",
              worker_id: worker_ctx.worker_id,
              payload: inspect(other)
            )

          {:error, reason} ->
            SLog.warning(
              @log_category,
              "Telemetry stream error for worker #{worker_ctx.worker_id}: #{inspect(reason)}",
              worker_id: worker_ctx.worker_id,
              reason: reason
            )

          {:trailers, trailers} ->
            SLog.debug(@log_category, "Telemetry stream trailers: #{inspect(trailers)}",
              worker_id: worker_ctx.worker_id
            )

          other ->
            SLog.warning(
              @log_category,
              "Unexpected telemetry stream item for worker #{worker_ctx.worker_id}",
              worker_id: worker_ctx.worker_id,
              item: inspect(other)
            )
        end)

        SLog.debug(@log_category, "Telemetry stream completed for worker #{worker_ctx.worker_id}",
          worker_id: worker_ctx.worker_id
        )

      {:error, reason} ->
        log_stream_closed(worker_ctx, reason)
    end
  end

  defp stream_capable_channel?(%Channel{}), do: true

  defp stream_capable_channel?(%{__struct__: module}) when is_atom(module) do
    String.starts_with?(Atom.to_string(module), "GRPC.")
  end

  defp stream_capable_channel?(_), do: false

  defp describe_channel(%Channel{}), do: "GRPC.Channel"
  defp describe_channel(%{__struct__: module}) when is_atom(module), do: Atom.to_string(module)
  defp describe_channel(channel) when is_reference(channel), do: "reference"
  defp describe_channel(channel) when is_pid(channel), do: "pid"
  defp describe_channel(channel) when is_map(channel), do: "map"
  defp describe_channel(channel) when is_binary(channel), do: "binary"
  defp describe_channel(channel) when is_list(channel), do: "list"
  defp describe_channel(channel), do: inspect(channel)

  defp log_stream_closed(worker_ctx, reason) do
    log_fun =
      if shutdown_reason?(reason), do: &SLog.debug/3, else: &SLog.warning/3

    log_fun.(
      @log_category,
      "Telemetry stream closed for worker #{worker_ctx.worker_id}: #{inspect(reason)}",
      worker_id: worker_ctx.worker_id,
      reason: reason
    )
  end

  defp shutdown_reason?(%GRPC.RPCError{message: message}) when is_binary(message) do
    message
    |> String.downcase()
    |> String.contains?("shutdown")
  end

  defp shutdown_reason?(%GRPC.RPCError{}), do: false
  defp shutdown_reason?(:shutdown), do: true
  defp shutdown_reason?({:shutdown, _}), do: true
  defp shutdown_reason?({:down, :shutdown}), do: true
  defp shutdown_reason?({:error, reason}), do: shutdown_reason?(reason)
  defp shutdown_reason?(_), do: false

  defp translate_and_emit(event, worker_ctx) do
    with {:ok, event_name} <- Naming.from_parts(event.event_parts),
         {:ok, measurements} <- cast_measurements(event.measurements),
         {:ok, metadata} <-
           SafeMetadata.enrich(event.metadata,
             node: node(),
             worker_id: worker_ctx.worker_id,
             pool_name: worker_ctx.pool_name,
             python_pid: worker_ctx.python_pid,
             correlation_id: blank_to_nil(event.correlation_id),
             timestamp_ns: event.timestamp_ns
           ) do
      :telemetry.execute(event_name, measurements, metadata)
    else
      {:error, reason} ->
        SLog.debug(
          @log_category,
          "Skipping telemetry event #{inspect(event.event_parts)}: #{inspect(reason)}",
          worker_id: worker_ctx.worker_id,
          event_parts: event.event_parts,
          reason: reason
        )
    end
  end

  defp cast_measurements(measurements) do
    Enum.reduce_while(measurements, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case Naming.measurement_key(key) do
        {:ok, atom_key} ->
          val = extract_measurement_value(value.value)
          {:cont, {:ok, Map.put(acc, atom_key, val)}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_measurement_key, key, reason}}}
      end
    end)
  end

  defp extract_measurement_value({:int_value, v}), do: v
  defp extract_measurement_value({:float_value, v}), do: v
  defp extract_measurement_value({:string_value, v}), do: v
  defp extract_measurement_value(nil), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp pop_stream_by_ref(state, ref) do
    case Enum.find(state.streams, fn {_worker_id, info} ->
           info.task && info.task.ref == ref
         end) do
      {worker_id, _info} ->
        {:ok, worker_id, update_in(state, [:streams], &Map.delete(&1, worker_id))}

      nil ->
        :error
    end
  end

  defp pop_stream_by_pid(state, pid) when is_pid(pid) do
    case Enum.find(state.streams, fn {_worker_id, info} ->
           info.task && info.task.pid == pid
         end) do
      {worker_id, _info} ->
        {:ok, worker_id, update_in(state, [:streams], &Map.delete(&1, worker_id))}

      nil ->
        :error
    end
  end

  defp pop_stream_by_pid(_state, _pid), do: :error

  defp log_task_exit(worker_id, reason) do
    SLog.debug(@log_category, "Telemetry stream consumer task exited: #{inspect(reason)}",
      worker_id: worker_id
    )
  end

  defp cancel_stream_open_timer(stream_info) do
    if is_reference(stream_info[:open_timer_ref]) do
      Process.cancel_timer(stream_info.open_timer_ref)
    end

    Map.put(stream_info, :open_timer_ref, nil)
  end

  defp shutdown_exit?(reason) when reason == :shutdown, do: true
  defp shutdown_exit?({:shutdown, _}), do: true
  defp shutdown_exit?(_), do: false
end
