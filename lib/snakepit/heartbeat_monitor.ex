defmodule Snakepit.HeartbeatMonitor do
  @moduledoc """
  Monitors a worker process using a configurable heartbeat protocol.

  The monitor periodically invokes a ping function and expects the worker
  to send a pong via `notify_pong/2`. Missed heartbeats trigger worker
  termination, allowing supervisors to restart the worker.
  """

  use GenServer
  require Logger

  @default_ping_interval 2_000
  @default_timeout 10_000
  @default_max_missed 3

  @type start_option ::
          {:worker_pid, pid()}
          | {:worker_id, String.t()}
          | {:ping_interval_ms, non_neg_integer()}
          | {:timeout_ms, non_neg_integer()}
          | {:max_missed_heartbeats, non_neg_integer()}
          | {:ping_fun, (integer() -> :ok | {:ok, term()} | {:error, term()} | term())}

  defstruct [
    :worker_pid,
    :worker_id,
    :ping_interval,
    :timeout,
    :max_missed_heartbeats,
    :ping_fun,
    :ping_timer,
    :timeout_timer,
    :last_ping_timestamp,
    missed_heartbeats: 0,
    stats: %{pings_sent: 0, pongs_received: 0, timeouts: 0}
  ]

  @spec start_link([start_option()]) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Notify the monitor that a pong response has been received.
  """
  @spec notify_pong(pid(), integer()) :: :ok
  def notify_pong(monitor_pid, timestamp) when is_pid(monitor_pid) do
    GenServer.cast(monitor_pid, {:pong, timestamp})
  end

  @doc """
  Retrieve current monitor status.
  """
  @spec get_status(pid()) :: map()
  def get_status(monitor_pid) do
    GenServer.call(monitor_pid, :get_status)
  end

  @impl true
  def init(opts) do
    worker_pid = Keyword.fetch!(opts, :worker_pid)
    worker_id = Keyword.fetch!(opts, :worker_id)

    ping_interval = Keyword.get(opts, :ping_interval_ms, @default_ping_interval)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout)
    max_missed = Keyword.get(opts, :max_missed_heartbeats, @default_max_missed)

    ping_fun =
      Keyword.get(opts, :ping_fun, &default_ping_fun/1)

    state = %__MODULE__{
      worker_pid: worker_pid,
      worker_id: worker_id,
      ping_interval: ping_interval,
      timeout: timeout,
      max_missed_heartbeats: max_missed,
      ping_fun: ping_fun
    }

    Process.monitor(worker_pid)
    {:ok, schedule_initial_ping(state)}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      worker_id: state.worker_id,
      worker_pid: state.worker_pid,
      missed_heartbeats: state.missed_heartbeats,
      last_ping_timestamp: state.last_ping_timestamp,
      stats: state.stats
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast({:pong, ping_timestamp}, state) do
    now = System.monotonic_time(:millisecond)

    if state.timeout_timer do
      Process.cancel_timer(state.timeout_timer)
    end

    new_stats =
      state.stats
      |> Map.update!(:pongs_received, &(&1 + 1))

    new_state =
      %{
        state
        | missed_heartbeats: 0,
          timeout_timer: nil,
          stats: new_stats,
          last_ping_timestamp: ping_timestamp
      }
      |> schedule_next_ping()

    emit_event(:pong_received, new_state, %{latency_ms: now - ping_timestamp})
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:send_ping, state) do
    timestamp = System.monotonic_time(:millisecond)

    result =
      try do
        state.ping_fun.(timestamp)
      rescue
        exception ->
          {:error, {exception, __STACKTRACE__}}
      catch
        kind, reason ->
          {:error, {kind, reason}}
      end

    case normalize_ping_result(result) do
      :ok ->
        stats = Map.update!(state.stats, :pings_sent, &(&1 + 1))

        new_state =
          %{state | stats: stats, last_ping_timestamp: timestamp}
          |> schedule_timeout()

        emit_event(:ping_sent, new_state, %{})
        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning("Heartbeat ping failed for #{state.worker_id}: #{inspect(reason)}")
        handle_worker_failure(state, :ping_failed)
    end
  end

  @impl true
  def handle_info(:heartbeat_timeout, state) do
    missed = state.missed_heartbeats + 1

    stats = Map.update!(state.stats, :timeouts, &(&1 + 1))

    emit_event(:heartbeat_timeout, %{state | missed_heartbeats: missed, stats: stats}, %{
      missed_count: missed
    })

    if missed >= state.max_missed_heartbeats do
      Logger.error(
        "Worker #{state.worker_id} missed #{missed} heartbeat(s); initiating termination"
      )

      handle_worker_failure(
        %{state | missed_heartbeats: missed, stats: stats},
        :heartbeat_timeout
      )
    else
      new_state =
        %{state | missed_heartbeats: missed, stats: stats, timeout_timer: nil}
        |> schedule_next_ping()

      {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{worker_pid: pid} = state) do
    Logger.debug("Heartbeat monitor observed worker #{state.worker_id} exit: #{inspect(reason)}")
    {:stop, {:worker_down, reason}, state}
  end

  @impl true
  def handle_info(message, state) do
    Logger.debug("Unhandled heartbeat monitor message: #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.ping_timer)
    cancel_timer(state.timeout_timer)
    :ok
  end

  defp default_ping_fun(_timestamp) do
    {:error, :not_implemented}
  end

  defp schedule_initial_ping(state) do
    timer = Process.send_after(self(), :send_ping, 0)
    %{state | ping_timer: timer}
  end

  defp schedule_next_ping(state) do
    cancel_timer(state.ping_timer)
    timer = Process.send_after(self(), :send_ping, state.ping_interval)
    %{state | ping_timer: timer}
  end

  defp schedule_timeout(state) do
    cancel_timer(state.timeout_timer)
    timer = Process.send_after(self(), :heartbeat_timeout, state.timeout)
    %{state | timeout_timer: timer}
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer_ref) do
    Process.cancel_timer(timer_ref, async: true, info: false)
    :ok
  end

  defp handle_worker_failure(state, reason) do
    Process.exit(state.worker_pid, {:shutdown, reason})
    {:stop, {:shutdown, reason}, state}
  end

  defp normalize_ping_result(:ok), do: :ok
  defp normalize_ping_result({:ok, _data}), do: :ok
  defp normalize_ping_result({:error, reason}), do: {:error, reason}
  defp normalize_ping_result(:error), do: {:error, :unknown}
  defp normalize_ping_result(other), do: {:error, other}

  defp emit_event(event, state, metadata) do
    :telemetry.execute(
      [:snakepit, :heartbeat, event],
      %{timestamp: System.monotonic_time(:millisecond), count: 1},
      Map.merge(
        %{
          worker_id: state.worker_id,
          worker_pid: state.worker_pid,
          missed_heartbeats: state.missed_heartbeats
        },
        metadata
      )
    )
  end
end
