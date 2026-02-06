defmodule Snakepit.Pool.WorkerSupervisor do
  @moduledoc """
  DynamicSupervisor for pool worker processes.

  This supervisor manages the lifecycle of workers:
  - Starts workers on demand
  - Handles crashes with automatic restarts
  - Provides clean shutdown of workers
  """

  use DynamicSupervisor
  alias Snakepit.Config
  alias Snakepit.Defaults
  alias Snakepit.Logger, as: SLog
  alias Snakepit.Pool.Registry, as: PoolRegistry
  alias Snakepit.Pool.Worker.StarterRegistry
  @log_category :pool
  @worker_pid_lookup_timeout_ms 1000
  @worker_pid_lookup_interval_ms 20

  @doc """
  Starts the worker supervisor.
  """
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      extra_arguments: [],
      max_restarts: Defaults.worker_supervisor_max_restarts(),
      max_seconds: Defaults.worker_supervisor_max_seconds()
    )
  end

  @doc """
  Starts a new pool worker with the given ID.

  ## Examples

      iex> Snakepit.Pool.WorkerSupervisor.start_worker("worker_123")
      {:ok, #PID<0.123.0>} # GRPCWorker PID
  """
  def start_worker(
        worker_id,
        worker_module \\ Snakepit.GRPCWorker,
        adapter_module \\ nil,
        pool_name \\ nil,
        worker_config \\ %{}
      )
      when is_binary(worker_id) do
    # Start the permanent starter supervisor, not the transient worker directly
    # This gives us automatic worker restarts without Pool intervention
    # CRITICAL FIX: Pass pool_name to Worker.Starter so workers know which pool to notify
    # v0.6.0: Pass worker_config for lifecycle management
    child_spec =
      {Snakepit.Pool.Worker.Starter,
       {worker_id, worker_module, adapter_module, pool_name, worker_config}}

    case safe_start_child(child_spec) do
      {:ok, starter_pid} ->
        handle_started_worker(worker_id, starter_pid, :started)

      {:error, {:already_started, starter_pid}} ->
        handle_started_worker(worker_id, starter_pid, :already_started)

      {:error, reason} = error ->
        SLog.error(
          @log_category,
          "Failed to start worker starter for #{worker_id}: #{inspect(reason)}"
        )

        error
    end
  end

  @doc """
  Stops a worker gracefully.
  """
  def stop_worker(worker_pid) when is_pid(worker_pid) do
    case PoolRegistry.get_worker_id_by_pid(worker_pid) do
      {:ok, worker_id} -> stop_worker(worker_id)
      {:error, :not_found} -> {:error, :worker_not_found}
    end
  end

  def stop_worker(worker_id) when is_binary(worker_id) do
    case StarterRegistry.get_starter_pid(worker_id) do
      {:ok, starter_pid} ->
        safe_terminate_child(starter_pid)

      {:error, :not_found} ->
        {:error, :worker_not_found}
    end
  end

  @doc """
  Lists all supervised workers.
  """
  def list_workers do
    case safe_which_children() do
      {:ok, children} ->
        Enum.map(children, fn {_, pid, _, _} -> pid end)

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Returns the count of active workers.
  """
  def worker_count do
    case safe_count_children() do
      {:ok, %{active: active}} -> active
      {:error, _reason} -> 0
    end
  end

  @doc """
  Restarts a worker by ID.
  """
  def restart_worker(worker_id) do
    case PoolRegistry.get_worker_pid(worker_id) do
      {:ok, old_pid} ->
        # Get port metadata before terminating so we can check if it's released
        %{current_port: current_port, requested_port: requested_port} =
          get_worker_port_info(old_pid)

        # Worker exists, terminate it and wait for resource cleanup
        with :ok <- stop_worker(worker_id),
             :ok <- wait_for_resource_cleanup(worker_id, current_port, requested_port) do
          start_worker(worker_id)
        else
          # Propagate termination/cleanup errors
          {:error, :worker_not_found} -> start_worker(worker_id)
          error -> error
        end

      {:error, :not_found} ->
        # Worker doesn't exist, so we just need to start it
        start_worker(worker_id)
    end
  end

  defp safe_start_child(child_spec) do
    if supervisor_alive?() do
      DynamicSupervisor.start_child(__MODULE__, child_spec)
    else
      {:error, :supervisor_not_running}
    end
  catch
    :exit, {:noproc, _} ->
      {:error, :supervisor_not_running}

    :exit, reason ->
      {:error, {:supervisor_call_failed, reason}}
  end

  defp safe_terminate_child(starter_pid) do
    if supervisor_alive?() do
      DynamicSupervisor.terminate_child(__MODULE__, starter_pid)
    else
      {:error, :supervisor_not_running}
    end
  catch
    :exit, {:noproc, _} ->
      {:error, :supervisor_not_running}

    :exit, reason ->
      {:error, {:supervisor_call_failed, reason}}
  end

  defp safe_which_children do
    if supervisor_alive?() do
      {:ok, DynamicSupervisor.which_children(__MODULE__)}
    else
      {:error, :supervisor_not_running}
    end
  catch
    :exit, {:noproc, _} ->
      {:error, :supervisor_not_running}

    :exit, reason ->
      {:error, {:supervisor_call_failed, reason}}
  end

  defp safe_count_children do
    if supervisor_alive?() do
      {:ok, DynamicSupervisor.count_children(__MODULE__)}
    else
      {:error, :supervisor_not_running}
    end
  catch
    :exit, {:noproc, _} ->
      {:error, :supervisor_not_running}

    :exit, reason ->
      {:error, {:supervisor_call_failed, reason}}
  end

  defp supervisor_alive? do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  defp cleanup_retry_interval_ms do
    Config.worker_supervisor_cleanup_retry_interval_ms()
  end

  defp cleanup_max_retries do
    Config.worker_supervisor_cleanup_max_retries()
  end

  # Wait for external resources to be released after worker termination.
  #
  # This is necessary because:
  # 1. DynamicSupervisor.terminate_child waits for Elixir process termination
  # 2. But external OS process + ports may still be shutting down
  # 3. Starting a new worker immediately can cause port binding conflicts
  #
  # We check:
  # - Port availability (can we bind to it?)
  # - Registry cleanup (entry removed?)
  #
  # This prevents race conditions on worker restart.
  # Uses exponential backoff for efficient polling: starts fast, backs off gradually.
  defp wait_for_resource_cleanup(
         worker_id,
         current_port,
         requested_port,
         retries \\ cleanup_max_retries(),
         backoff \\ cleanup_retry_interval_ms()
       ) do
    if retries > 0 do
      check_and_wait_for_cleanup(worker_id, current_port, requested_port, retries, backoff)
    else
      handle_cleanup_timeout(worker_id)
    end
  end

  defp check_and_wait_for_cleanup(worker_id, current_port, requested_port, retries, backoff) do
    port_to_probe = port_probe_target(current_port, requested_port)
    probe_port? = should_probe_port?(requested_port) and port_to_probe not in [nil, 0]

    maybe_delay_initial_probe(probe_port?, retries, backoff)

    port_released? = check_port_released(worker_id, port_to_probe, probe_port?, retries)

    if port_released? and registry_cleaned?(worker_id) do
      SLog.debug(@log_category, "Resources released for #{worker_id}, safe to restart")
      :ok
    else
      retry_cleanup_check(worker_id, current_port, requested_port, retries, backoff)
    end
  end

  defp maybe_delay_initial_probe(probe_port?, retries, backoff) do
    if probe_port? and retries == cleanup_max_retries() do
      initial_delay = min(backoff, 50)

      receive do
      after
        initial_delay -> :ok
      end
    end
  end

  defp check_port_released(worker_id, port_to_probe, probe_port?, retries) do
    if probe_port? do
      SLog.debug(@log_category, "Probing port #{port_to_probe} before restarting #{worker_id}")
      port_available?(port_to_probe)
    else
      log_ephemeral_port_skip(worker_id, retries)
      true
    end
  end

  defp log_ephemeral_port_skip(worker_id, retries) do
    if retries == cleanup_max_retries() do
      SLog.info(
        @log_category,
        "Skipping port availability probe for #{worker_id}; worker requested an ephemeral port"
      )
    end
  end

  defp retry_cleanup_check(worker_id, current_port, requested_port, retries, backoff) do
    delay = min(backoff, 200)

    receive do
    after
      delay -> :ok
    end

    wait_for_resource_cleanup(
      worker_id,
      current_port,
      requested_port,
      retries - 1,
      backoff * 2
    )
  end

  defp handle_cleanup_timeout(worker_id) do
    SLog.warning(
      @log_category,
      "Resource cleanup timeout for #{worker_id} after #{cleanup_max_retries()} retries, " <>
        "proceeding with restart anyway"
    )

    {:error, :cleanup_timeout}
  end

  defp get_worker_port_info(worker_pid) do
    case GenServer.call(worker_pid, :get_port_metadata, 1000) do
      {:ok, %{current_port: port} = info} ->
        %{
          current_port: port,
          requested_port: Map.get(info, :requested_port)
        }

      _ ->
        legacy_port_info(worker_pid)
    end
  catch
    :exit, _ -> %{current_port: nil, requested_port: nil}
  end

  defp legacy_port_info(worker_pid) do
    case GenServer.call(worker_pid, :get_port, 1000) do
      {:ok, port} -> %{current_port: port, requested_port: port}
      _ -> %{current_port: nil, requested_port: nil}
    end
  catch
    :exit, _ -> %{current_port: nil, requested_port: nil}
  end

  defp port_available?(port) when is_integer(port) do
    # Try to bind to the port to verify it's available
    case :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, :eaddrinuse} ->
        false

      {:error, _other} ->
        # Other errors (permission, etc) - assume unavailable
        false
    end
  end

  # No port to check
  defp port_available?(nil), do: true

  defp registry_cleaned?(worker_id) do
    case PoolRegistry.get_worker_pid(worker_id) do
      {:error, :not_found} -> true
      {:ok, _pid} -> false
    end
  end

  @doc false
  def port_probe_target(current_port, requested_port) do
    cond do
      current_port not in [nil, 0] -> current_port
      requested_port not in [nil, 0] -> requested_port
      true -> nil
    end
  end

  defp should_probe_port?(requested_port) do
    requested_port not in [nil, 0]
  end

  defp handle_started_worker(worker_id, starter_pid, status) do
    case resolve_worker_pid(worker_id, starter_pid) do
      {:ok, worker_pid} ->
        log_worker_start(worker_id, starter_pid, worker_pid, status)
        {:ok, worker_pid}

      {:error, reason} ->
        SLog.error(
          @log_category,
          "Started worker starter for #{worker_id} (PID #{inspect(starter_pid)}), " <>
            "but failed to resolve worker PID: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp log_worker_start(worker_id, starter_pid, worker_pid, :started) do
    SLog.info(
      @log_category,
      "Started worker #{worker_id} with starter PID #{inspect(starter_pid)} and worker PID #{inspect(worker_pid)}"
    )
  end

  defp log_worker_start(worker_id, starter_pid, worker_pid, :already_started) do
    SLog.debug(
      @log_category,
      "Worker starter for #{worker_id} already running (starter PID #{inspect(starter_pid)}, worker PID #{inspect(worker_pid)})"
    )
  end

  defp resolve_worker_pid(worker_id, starter_pid) do
    case worker_pid_from_starter(starter_pid, worker_id) do
      {:ok, worker_pid} ->
        {:ok, worker_pid}

      {:error, _reason} ->
        wait_for_worker_pid(worker_id, starter_pid, @worker_pid_lookup_timeout_ms)
    end
  end

  defp wait_for_worker_pid(worker_id, starter_pid, timeout_ms) when timeout_ms > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_worker_pid_loop(worker_id, starter_pid, deadline)
  end

  defp wait_for_worker_pid(worker_id, starter_pid, _timeout_ms) do
    case worker_pid_from_starter(starter_pid, worker_id) do
      {:ok, worker_pid} -> {:ok, worker_pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp wait_for_worker_pid_loop(worker_id, starter_pid, deadline) do
    case worker_pid_from_starter(starter_pid, worker_id) do
      {:ok, worker_pid} ->
        {:ok, worker_pid}

      {:error, _reason} ->
        case PoolRegistry.get_worker_pid(worker_id) do
          {:ok, worker_pid} ->
            {:ok, worker_pid}

          {:error, :not_found} ->
            if System.monotonic_time(:millisecond) >= deadline do
              {:error, :worker_pid_unavailable}
            else
              receive do
              after
                @worker_pid_lookup_interval_ms -> :ok
              end

              wait_for_worker_pid_loop(worker_id, starter_pid, deadline)
            end
        end
    end
  end

  defp worker_pid_from_starter(starter_pid, worker_id) when is_pid(starter_pid) do
    case Supervisor.which_children(starter_pid) do
      [{^worker_id, worker_pid, :worker, _}] when is_pid(worker_pid) ->
        {:ok, worker_pid}

      [{^worker_id, :restarting, :worker, _}] ->
        {:error, :worker_restarting}

      [{^worker_id, :undefined, :worker, _}] ->
        {:error, :worker_not_ready}

      children when is_list(children) ->
        case Enum.find(children, fn {_, pid, type, _} -> type == :worker and is_pid(pid) end) do
          {_id, pid, :worker, _} when is_pid(pid) -> {:ok, pid}
          _ -> {:error, :worker_not_ready}
        end
    end
  catch
    :exit, _ -> {:error, :starter_down}
  end
end
