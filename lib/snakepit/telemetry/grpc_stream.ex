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
  require Logger

  alias Snakepit.Bridge.{BridgeService, TelemetryEvent}
  alias Snakepit.Telemetry.{Control, Naming, SafeMetadata}

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
    GenServer.cast(__MODULE__, {:register_worker, channel, worker_ctx})
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
    GenServer.call(__MODULE__, :list_streams)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    {:ok, %{streams: %{}}}
  end

  @impl true
  def handle_cast({:register_worker, channel, worker_ctx}, state) do
    case initiate_stream(channel, worker_ctx) do
      {:ok, stream_info} ->
        new_state = put_in(state, [:streams, worker_ctx.worker_id], stream_info)

        Logger.info(
          "Telemetry stream registered for worker #{worker_ctx.worker_id}",
          worker_id: worker_ctx.worker_id,
          pool_name: worker_ctx.pool_name
        )

        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning(
          "Failed to register telemetry stream for worker #{worker_ctx.worker_id}: #{inspect(reason)}",
          worker_id: worker_ctx.worker_id,
          reason: reason
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:unregister_worker, worker_id}, state) do
    case Map.get(state.streams, worker_id) do
      nil ->
        {:noreply, state}

      stream_info ->
        # Cancel the consumer task
        if stream_info.task && Process.alive?(stream_info.task.pid) do
          Task.shutdown(stream_info.task, :brutal_kill)
        end

        new_state = update_in(state, [:streams], &Map.delete(&1, worker_id))

        Logger.debug("Telemetry stream unregistered for worker #{worker_id}",
          worker_id: worker_id
        )

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast({:update_sampling, worker_id, rate, patterns}, state) do
    case Map.get(state.streams, worker_id) do
      nil ->
        Logger.debug("Cannot update sampling for unknown worker #{worker_id}")
        {:noreply, state}

      %{stream: stream} ->
        control_msg = Control.sampling(rate, patterns)

        case GRPC.Stub.send_request(stream, control_msg) do
          {:ok, _} ->
            Logger.debug("Updated sampling for worker #{worker_id} to #{rate}",
              worker_id: worker_id,
              rate: rate,
              patterns: patterns
            )

          {:error, reason} ->
            Logger.warning(
              "Failed to update sampling for worker #{worker_id}: #{inspect(reason)}",
              worker_id: worker_id,
              reason: reason
            )
        end

        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:toggle, worker_id, enabled}, state) do
    case Map.get(state.streams, worker_id) do
      nil ->
        {:noreply, state}

      %{stream: stream} ->
        control_msg = Control.toggle(enabled)

        case GRPC.Stub.send_request(stream, control_msg) do
          {:ok, _} ->
            Logger.debug("Toggled telemetry for worker #{worker_id} to #{enabled}",
              worker_id: worker_id,
              enabled: enabled
            )

          {:error, reason} ->
            Logger.warning(
              "Failed to toggle telemetry for worker #{worker_id}: #{inspect(reason)}",
              worker_id: worker_id,
              reason: reason
            )
        end

        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:update_filter, worker_id, opts}, state) do
    case Map.get(state.streams, worker_id) do
      nil ->
        {:noreply, state}

      %{stream: stream} ->
        control_msg = Control.filter(opts)

        case GRPC.Stub.send_request(stream, control_msg) do
          {:ok, _} ->
            Logger.debug("Updated filters for worker #{worker_id}", worker_id: worker_id)

          {:error, reason} ->
            Logger.warning(
              "Failed to update filters for worker #{worker_id}: #{inspect(reason)}",
              worker_id: worker_id,
              reason: reason
            )
        end

        {:noreply, state}
    end
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
  def handle_info({ref, :stream_completed}, state) when is_reference(ref) do
    # Task completed successfully
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    # Task crashed or was killed
    Logger.debug("Telemetry stream consumer task terminated: #{inspect(reason)}")
    {:noreply, state}
  end

  ## Private Helpers

  defp initiate_stream(channel, worker_ctx) do
    # Use longer timeout for stream operations
    case BridgeService.Stub.stream_telemetry(channel, timeout: :infinity) do
      {:ok, stream} ->
        # Send initial toggle message to enable telemetry
        stream = GRPC.Stub.send_request(stream, Control.toggle(true))

        # Start async task to consume events
        task =
          Task.Supervisor.async_nolink(
            Snakepit.TaskSupervisor,
            fn -> consume_stream(stream, worker_ctx) end
          )

        {:ok,
         %{
           stream: stream,
           task: task,
           worker_ctx: worker_ctx,
           started_at: System.monotonic_time()
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp consume_stream(stream, worker_ctx) do
    case GRPC.Stub.recv(stream, timeout: :infinity) do
      {:ok, enum} ->
        Enum.each(enum, fn
          {:ok, %TelemetryEvent{} = event} ->
            translate_and_emit(event, worker_ctx)

          {:error, reason} ->
            Logger.warning(
              "Telemetry stream error for worker #{worker_ctx.worker_id}: #{inspect(reason)}",
              worker_id: worker_ctx.worker_id,
              reason: reason
            )

          {:trailers, trailers} ->
            Logger.debug("Telemetry stream trailers: #{inspect(trailers)}",
              worker_id: worker_ctx.worker_id
            )
        end)

        Logger.debug("Telemetry stream completed for worker #{worker_ctx.worker_id}",
          worker_id: worker_ctx.worker_id
        )

      {:error, reason} ->
        Logger.warning(
          "Telemetry stream closed for worker #{worker_ctx.worker_id}: #{inspect(reason)}",
          worker_id: worker_ctx.worker_id,
          reason: reason
        )
    end
  end

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
        Logger.debug(
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
          val =
            case value.value do
              {:int_value, v} -> v
              {:float_value, v} -> v
              {:string_value, v} -> v
              nil -> nil
            end

          {:cont, {:ok, Map.put(acc, atom_key, val)}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_measurement_key, key, reason}}}
      end
    end)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
