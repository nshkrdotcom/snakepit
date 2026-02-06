defmodule Snakepit.Worker.LifecycleManagerTest do
  use ExUnit.Case, async: false

  alias Snakepit.Worker.LifecycleManager

  defmodule MinimalProfile do
    @behaviour Snakepit.WorkerProfile

    def start_worker(_config), do: {:error, :not_implemented}
    def stop_worker(_worker), do: :ok
    def execute_request(_worker, _request, _timeout), do: {:ok, %{}}
    def get_capacity(_worker), do: 1
    def get_load(_worker), do: 0
    def health_check(_worker), do: :ok
    def get_metadata(_worker), do: {:ok, %{profile: :minimal}}
  end

  defmodule SlowStopProfile do
    @behaviour Snakepit.WorkerProfile
    @stop_hook_key {__MODULE__, :stop_hook}

    def start_worker(_config), do: {:error, :replacement_failed}

    def stop_worker(pid) when is_pid(pid) do
      maybe_wait_for_release(pid)

      send(pid, :stop)
      :ok
    end

    def execute_request(_worker, _request, _timeout), do: {:ok, %{}}
    def get_capacity(_worker), do: 1
    def get_load(_worker), do: 0
    def health_check(_worker), do: :ok
    def get_metadata(_worker), do: {:ok, %{profile: :slow_stop}}

    defp maybe_wait_for_release(worker_pid) do
      case :persistent_term.get(@stop_hook_key, nil) do
        {test_pid, gate_ref} ->
          send(test_pid, {:stop_worker_called, gate_ref, self(), worker_pid})

          receive do
            {:allow_stop, ^gate_ref} -> :ok
          after
            1_000 -> :ok
          end

        _ ->
          :ok
      end
    end
  end

  defmodule SlowHealthProfile do
    @behaviour Snakepit.WorkerProfile
    @health_hook_key {__MODULE__, :health_hook}

    def start_worker(_config), do: {:error, :not_implemented}
    def stop_worker(_worker), do: :ok
    def execute_request(_worker, _request, _timeout), do: {:ok, %{}}
    def get_capacity(_worker), do: 1
    def get_load(_worker), do: 0
    def get_metadata(_worker), do: {:ok, %{profile: :slow_health}}

    def health_check(worker_pid) do
      maybe_wait_for_release(worker_pid)
      :ok
    end

    defp maybe_wait_for_release(worker_pid) do
      case :persistent_term.get(@health_hook_key, nil) do
        {test_pid, gate_ref} ->
          send(test_pid, {:health_check_started, gate_ref, self(), worker_pid})

          receive do
            {:allow_health_check, ^gate_ref} -> :ok
          after
            1_000 -> :ok
          end

        _ ->
          :ok
      end
    end
  end

  test "untrack demonitor flushes tracked worker monitor" do
    worker_pid = spawn_worker()
    worker_id = "worker_#{System.unique_integer([:positive])}"

    {:noreply, tracked_state} =
      LifecycleManager.handle_cast(
        {:track, :test_pool, worker_id, worker_pid, lifecycle_config(MinimalProfile)},
        base_state()
      )

    assert monitored_process?(worker_pid)

    {:noreply, _state} = LifecycleManager.handle_cast({:untrack, worker_id}, tracked_state)

    refute monitored_process?(worker_pid)
    Process.exit(worker_pid, :kill)
  end

  test "recycle cast callback does not block on slow stop/start work" do
    worker_pid = spawn_worker()
    worker_monitor = Process.monitor(worker_pid)
    worker_id = "worker_#{System.unique_integer([:positive])}"
    gate_ref = install_stop_hook()

    {:noreply, tracked_state} =
      LifecycleManager.handle_cast(
        {:track, :test_pool, worker_id, worker_pid, lifecycle_config(SlowStopProfile)},
        base_state()
      )

    {:noreply, _new_state} =
      LifecycleManager.handle_cast({:recycle_worker, worker_id, :test_recycle}, tracked_state)

    assert_receive {:stop_worker_called, ^gate_ref, stopper_pid, ^worker_pid}, 1_000
    send(stopper_pid, {:allow_stop, gate_ref})

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker_pid, :normal}, 1_000
  end

  test "manual recycle call returns promptly while recycle runs asynchronously" do
    worker_pid = spawn_worker()
    worker_monitor = Process.monitor(worker_pid)
    worker_id = "worker_#{System.unique_integer([:positive])}"
    gate_ref = install_stop_hook()

    {:noreply, tracked_state} =
      LifecycleManager.handle_cast(
        {:track, :test_pool, worker_id, worker_pid, lifecycle_config(SlowStopProfile)},
        base_state()
      )

    {:reply, :ok, _new_state} =
      LifecycleManager.handle_call(
        {:recycle, :test_pool, worker_id},
        {self(), make_ref()},
        tracked_state
      )

    assert_receive {:stop_worker_called, ^gate_ref, stopper_pid, ^worker_pid}, 1_000
    send(stopper_pid, {:allow_stop, gate_ref})

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker_pid, :normal}, 1_000
  end

  test "recycle fallback task still runs when TaskSupervisor is unavailable" do
    on_exit(fn ->
      Application.ensure_all_started(:snakepit)
    end)

    Application.stop(:snakepit)

    worker_pid = spawn_worker()
    worker_monitor = Process.monitor(worker_pid)
    worker_id = "worker_#{System.unique_integer([:positive])}"
    gate_ref = install_stop_hook()

    {:noreply, tracked_state} =
      LifecycleManager.handle_cast(
        {:track, :test_pool, worker_id, worker_pid, lifecycle_config(SlowStopProfile)},
        base_state()
      )

    {:noreply, _new_state} =
      LifecycleManager.handle_cast({:recycle_worker, worker_id, :fallback_recycle}, tracked_state)

    assert_receive {:stop_worker_called, ^gate_ref, stopper_pid, ^worker_pid}, 1_000
    send(stopper_pid, {:allow_stop, gate_ref})

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker_pid, :normal}, 1_000
  end

  test "health checks are bounded and do not block callback mailbox under slow profiles" do
    worker_pid = spawn_worker()
    worker_id = "worker_#{System.unique_integer([:positive])}"
    gate_ref = install_health_hook()

    {:noreply, tracked_state} =
      LifecycleManager.handle_cast(
        {:track, :test_pool, worker_id, worker_pid, lifecycle_config(SlowHealthProfile)},
        base_state()
      )

    start_ms = System.monotonic_time(:millisecond)

    {:noreply, state_after_health} =
      LifecycleManager.handle_info(:health_check, tracked_state)

    elapsed_ms = System.monotonic_time(:millisecond) - start_ms

    assert elapsed_ms < 100
    assert_receive {:health_check_started, ^gate_ref, checker_pid, ^worker_pid}, 1_000
    send(checker_pid, {:allow_health_check, gate_ref})

    Process.cancel_timer(state_after_health.health_ref)
    Process.exit(worker_pid, :kill)
  end

  defp lifecycle_config(profile_module) do
    %{
      worker_profile: profile_module,
      worker_module: Snakepit.GRPCWorker,
      adapter_module: Snakepit.TestAdapters.MockGRPCAdapter,
      pool_name: :test_pool
    }
  end

  defp base_state do
    %LifecycleManager{
      workers: %{},
      check_ref: nil,
      health_ref: nil,
      memory_recycle_counts: %{},
      lifecycle_task_ref: nil
    }
  end

  defp spawn_worker do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp install_stop_hook do
    gate_ref = make_ref()
    stop_hook_key = {SlowStopProfile, :stop_hook}
    :persistent_term.put(stop_hook_key, {self(), gate_ref})

    on_exit(fn ->
      :persistent_term.erase(stop_hook_key)
    end)

    gate_ref
  end

  defp install_health_hook do
    gate_ref = make_ref()
    health_hook_key = {SlowHealthProfile, :health_hook}
    :persistent_term.put(health_hook_key, {self(), gate_ref})

    on_exit(fn ->
      :persistent_term.erase(health_hook_key)
    end)

    gate_ref
  end

  defp monitored_process?(worker_pid) when is_pid(worker_pid) do
    case Process.info(self(), :monitors) do
      {:monitors, monitors} ->
        Enum.any?(monitors, fn
          {:process, ^worker_pid} -> true
          _ -> false
        end)

      _ ->
        false
    end
  end
end
