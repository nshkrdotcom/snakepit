defmodule Snakepit.Telemetry.GPUProfiler do
  @moduledoc """
  GPU memory and utilization profiler.

  > #### Legacy Optional Module {: .warning}
  >
  > `Snakepit` does not call this module internally. It remains available for
  > compatibility and may be removed in `v0.16.0` or later.
  >
  > Prefer host-managed GPU sampling and direct `:telemetry` emission for new
  > integrations.

  Periodically samples GPU metrics and emits telemetry events.
  Supports NVIDIA CUDA GPUs via nvidia-smi.
  """

  use GenServer

  require Logger

  alias Snakepit.Hardware
  alias Snakepit.Internal.Deprecation

  @default_interval_ms 5_000
  @min_interval_ms 100
  @legacy_replacement "Use host-managed GPU samplers and emit telemetry directly"
  @legacy_remove_after "v0.16.0"

  @type state :: %{
          interval_ms: pos_integer(),
          enabled: boolean(),
          sample_count: non_neg_integer(),
          last_sample_time: integer() | nil,
          timer_ref: reference() | nil,
          devices: [Hardware.Selector.device()],
          sampler_fun: (Hardware.Selector.device() -> {:ok, map()} | {:error, term()}),
          sample_task_ref: reference() | nil,
          sample_task_pid: pid() | nil,
          sample_now_waiters: [GenServer.from()]
        }

  # Client API

  @doc """
  Starts the GPU profiler.

  ## Options

  - `:interval_ms` - Sampling interval in milliseconds (default: 5000)
  - `:enabled` - Whether to start sampling immediately (default: true)
  - `:name` - GenServer name (default: __MODULE__)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    mark_legacy_usage()
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Triggers an immediate GPU sample.
  """
  @spec sample_now(GenServer.server()) :: :ok | {:error, :no_gpu}
  def sample_now(server \\ __MODULE__) do
    mark_legacy_usage()
    GenServer.call(server, :sample_now)
  end

  @doc """
  Returns profiler statistics.
  """
  @spec get_stats(GenServer.server()) :: map()
  def get_stats(server \\ __MODULE__) do
    mark_legacy_usage()
    GenServer.call(server, :get_stats)
  end

  @doc """
  Enables GPU sampling.
  """
  @spec enable(GenServer.server()) :: :ok
  def enable(server \\ __MODULE__) do
    mark_legacy_usage()
    GenServer.call(server, :enable)
  end

  @doc """
  Disables GPU sampling.
  """
  @spec disable(GenServer.server()) :: :ok
  def disable(server \\ __MODULE__) do
    mark_legacy_usage()
    GenServer.call(server, :disable)
  end

  @doc """
  Updates the sampling interval.
  """
  @spec set_interval(GenServer.server(), pos_integer()) :: :ok | {:error, :invalid_interval}
  def set_interval(server \\ __MODULE__, interval_ms) do
    mark_legacy_usage()
    GenServer.call(server, {:set_interval, interval_ms})
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    enabled = Keyword.get(opts, :enabled, true)

    state = %{
      interval_ms: interval_ms,
      enabled: enabled,
      sample_count: 0,
      last_sample_time: nil,
      timer_ref: nil,
      devices: detect_gpu_devices(),
      sampler_fun: Keyword.get(opts, :sampler_fun, &sample_device/1),
      sample_task_ref: nil,
      sample_task_pid: nil,
      sample_now_waiters: []
    }

    state =
      if enabled and state.devices != [] do
        schedule_sample(state)
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_call(:sample_now, _from, %{devices: []} = state) do
    {:reply, {:error, :no_gpu}, state}
  end

  def handle_call(:sample_now, from, state) do
    state =
      state
      |> enqueue_sample_now_waiter(from)
      |> maybe_start_sample_task()

    {:noreply, state}
  end

  def handle_call(:get_stats, _from, state) do
    stats = %{
      interval_ms: state.interval_ms,
      enabled: state.enabled,
      sample_count: state.sample_count,
      last_sample_time: state.last_sample_time,
      device_count: length(state.devices)
    }

    {:reply, stats, state}
  end

  def handle_call(:enable, _from, state) do
    state = %{state | enabled: true}
    state = if state.devices != [], do: schedule_sample(state), else: state
    {:reply, :ok, state}
  end

  def handle_call(:disable, _from, state) do
    state = cancel_timer(state)
    state = %{state | enabled: false}
    {:reply, :ok, state}
  end

  def handle_call({:set_interval, interval_ms}, _from, state)
      when interval_ms >= @min_interval_ms do
    state = cancel_timer(state)
    state = %{state | interval_ms: interval_ms}
    state = if state.enabled and state.devices != [], do: schedule_sample(state), else: state
    {:reply, :ok, state}
  end

  def handle_call({:set_interval, _}, _from, state) do
    {:reply, {:error, :invalid_interval}, state}
  end

  @impl true
  def handle_info(:sample, state) do
    state = maybe_start_sample_task(state)

    state = if state.enabled, do: schedule_sample(state), else: state
    {:noreply, state}
  end

  def handle_info(
        {:gpu_sample_complete, pid, {:ok, sampled_at_ms}},
        %{sample_task_pid: pid} = state
      ) do
    maybe_demonitor_sample_task(state.sample_task_ref)

    state =
      state
      |> clear_sample_task()
      |> Map.update!(:sample_count, &(&1 + 1))
      |> Map.put(:last_sample_time, sampled_at_ms)

    state = reply_sample_now_waiters(state, :ok)
    {:noreply, state}
  end

  def handle_info({:gpu_sample_complete, pid, {:error, reason}}, %{sample_task_pid: pid} = state) do
    maybe_demonitor_sample_task(state.sample_task_ref)
    state = state |> clear_sample_task() |> reply_sample_now_waiters({:error, reason})
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, :normal}, %{sample_task_ref: ref} = state) do
    # Completion message may still be in flight; wait for {:gpu_sample_complete, ...}.
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{sample_task_ref: ref} = state) do
    state = state |> clear_sample_task() |> reply_sample_now_waiters({:error, reason})
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    state = cancel_timer(state)
    _state = stop_sample_task(state)
    :ok
  end

  # Private functions

  defp detect_gpu_devices do
    info = Hardware.detect()

    case info.cuda do
      %{devices: devices} when is_list(devices) and devices != [] ->
        Enum.map(devices, fn d -> {:cuda, d.id} end)

      _ ->
        []
    end
  end

  defp schedule_sample(state) do
    state = cancel_timer(state)
    ref = Process.send_after(self(), :sample, state.interval_ms)
    %{state | timer_ref: ref}
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(%{timer_ref: ref} = state) do
    Process.cancel_timer(ref, async: true, info: false)
    %{state | timer_ref: nil}
  end

  defp do_sample(devices, sampler_fun) when is_list(devices) and is_function(sampler_fun, 1) do
    if devices == [] do
      {:error, :no_gpu}
    else
      now = System.monotonic_time(:millisecond)

      Enum.each(devices, fn device ->
        case sampler_fun.(device) do
          {:ok, metrics} ->
            emit_metrics(device, metrics)

          {:error, _reason} ->
            :ok
        end
      end)

      {:ok, now}
    end
  end

  defp maybe_start_sample_task(%{devices: []} = state), do: state

  defp maybe_start_sample_task(%{sample_task_ref: ref} = state) when is_reference(ref), do: state

  defp maybe_start_sample_task(state) do
    parent = self()
    devices = state.devices
    sampler_fun = state.sampler_fun

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result = do_sample(devices, sampler_fun)
        send(parent, {:gpu_sample_complete, self(), result})
      end)

    %{state | sample_task_ref: monitor_ref, sample_task_pid: pid}
  end

  defp enqueue_sample_now_waiter(state, from) do
    Map.update(state, :sample_now_waiters, [from], fn waiters -> [from | waiters] end)
  end

  defp reply_sample_now_waiters(state, reply) do
    waiters = Map.get(state, :sample_now_waiters, [])

    Enum.each(waiters, fn from ->
      GenServer.reply(from, reply)
    end)

    Map.put(state, :sample_now_waiters, [])
  end

  defp clear_sample_task(state) do
    %{state | sample_task_ref: nil, sample_task_pid: nil}
  end

  defp maybe_demonitor_sample_task(ref) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
  end

  defp maybe_demonitor_sample_task(_), do: :ok

  defp stop_sample_task(state) do
    if is_pid(state.sample_task_pid) and Process.alive?(state.sample_task_pid) do
      Process.exit(state.sample_task_pid, :kill)
    end

    maybe_demonitor_sample_task(state.sample_task_ref)
    clear_sample_task(state)
  end

  defp sample_device({:cuda, device_id}) do
    query = [
      "--id=#{device_id}",
      "--query-gpu=memory.used,memory.total,memory.free,utilization.gpu,temperature.gpu,power.draw",
      "--format=csv,noheader,nounits"
    ]

    case System.cmd("nvidia-smi", query, stderr_to_stdout: true) do
      {output, 0} ->
        parse_nvidia_smi_output(output)

      _ ->
        {:error, :nvidia_smi_failed}
    end
  rescue
    _ -> {:error, :nvidia_smi_not_found}
  end

  defp sample_device(_), do: {:error, :unsupported_device}

  defp parse_nvidia_smi_output(output) do
    case String.split(String.trim(output), ", ") do
      [used, total, free, gpu_util, temp, power] ->
        {:ok,
         %{
           memory_used_mb: parse_int(used),
           memory_total_mb: parse_int(total),
           memory_free_mb: parse_int(free),
           gpu_utilization: parse_float(gpu_util),
           temperature: parse_float(temp),
           power_watts: parse_float(power)
         }}

      _ ->
        {:error, :parse_error}
    end
  end

  defp parse_int(str) do
    case Integer.parse(String.trim(str)) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_float(str) do
    case Float.parse(String.trim(str)) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp emit_metrics(device, metrics) do
    # Memory event
    :telemetry.execute(
      [:snakepit, :gpu, :memory, :sampled],
      %{
        used_mb: metrics.memory_used_mb,
        total_mb: metrics.memory_total_mb,
        free_mb: metrics.memory_free_mb
      },
      %{
        device: device,
        utilization: metrics.memory_used_mb / max(metrics.memory_total_mb, 1)
      }
    )

    # Utilization event
    :telemetry.execute(
      [:snakepit, :gpu, :utilization, :sampled],
      %{
        gpu_percent: metrics.gpu_utilization,
        memory_percent: metrics.memory_used_mb / max(metrics.memory_total_mb, 1) * 100
      },
      %{device: device}
    )

    # Temperature event
    if metrics.temperature > 0 do
      :telemetry.execute(
        [:snakepit, :gpu, :temperature, :sampled],
        %{celsius: metrics.temperature},
        %{device: device}
      )
    end

    # Power event
    if metrics.power_watts > 0 do
      :telemetry.execute(
        [:snakepit, :gpu, :power, :sampled],
        %{watts: metrics.power_watts, limit_watts: 0.0},
        %{device: device}
      )
    end
  end

  defp mark_legacy_usage do
    Deprecation.emit_legacy_module_used(__MODULE__,
      replacement: @legacy_replacement,
      remove_after: @legacy_remove_after
    )
  end
end
