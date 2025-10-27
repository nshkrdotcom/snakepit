defmodule Snakepit.Pool.WorkerSupervisor do
  @moduledoc """
  DynamicSupervisor for pool worker processes.

  This supervisor manages the lifecycle of workers:
  - Starts workers on demand
  - Handles crashes with automatic restarts
  - Provides clean shutdown of workers
  """

  use DynamicSupervisor
  require Logger
  alias Snakepit.Logger, as: SLog
  alias Snakepit.Pool.Registry, as: PoolRegistry
  alias Snakepit.Pool.Worker.StarterRegistry

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
      extra_arguments: []
    )
  end

  @doc """
  Starts a new pool worker with the given ID.

  ## Examples

      iex> Snakepit.Pool.WorkerSupervisor.start_worker("worker_123")
      {:ok, #PID<0.123.0>}
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

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, starter_pid} ->
        SLog.info("Started worker starter for #{worker_id} with PID #{inspect(starter_pid)}")
        {:ok, starter_pid}

      {:error, {:already_started, starter_pid}} ->
        SLog.debug(
          "Worker starter for #{worker_id} already running with PID #{inspect(starter_pid)}"
        )

        {:ok, starter_pid}

      {:error, reason} = error ->
        SLog.error("Failed to start worker starter for #{worker_id}: #{inspect(reason)}")
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
        DynamicSupervisor.terminate_child(__MODULE__, starter_pid)

      {:error, :not_found} ->
        {:error, :worker_not_found}
    end
  end

  @doc """
  Lists all supervised workers.
  """
  def list_workers do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.map(fn {_, pid, _, _} -> pid end)
  end

  @doc """
  Returns the count of active workers.
  """
  def worker_count do
    DynamicSupervisor.count_children(__MODULE__).active
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

  @cleanup_retry_interval Application.compile_env(:snakepit, :cleanup_retry_interval, 50)
  @cleanup_max_retries Application.compile_env(:snakepit, :cleanup_max_retries, 20)

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
         retries \\ @cleanup_max_retries,
         backoff \\ @cleanup_retry_interval
       ) do
    if retries > 0 do
      port_to_probe = port_probe_target(current_port, requested_port)
      probe_port? = should_probe_port?(requested_port) and port_to_probe not in [nil, 0]

      if probe_port? and retries == @cleanup_max_retries do
        initial_delay = min(backoff, 50)

        receive do
        after
          initial_delay -> :ok
        end
      end

      port_released? =
        cond do
          not probe_port? ->
            if retries == @cleanup_max_retries do
              SLog.info(
                "Skipping port availability probe for #{worker_id}; worker requested an ephemeral port"
              )
            end

            true

          true ->
            SLog.debug("Probing port #{port_to_probe} before restarting #{worker_id}")
            port_available?(port_to_probe)
        end

      if port_released? and registry_cleaned?(worker_id) do
        SLog.debug("Resources released for #{worker_id}, safe to restart")
        :ok
      else
        # Resources still in use - exponential backoff with cap at 200ms
        delay = min(backoff, 200)

        # OTP-idiomatic non-blocking wait
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
    else
      SLog.warning(
        "Resource cleanup timeout for #{worker_id} after #{@cleanup_max_retries} retries, " <>
          "proceeding with restart anyway"
      )

      {:error, :cleanup_timeout}
    end
  end

  defp get_worker_port_info(worker_pid) do
    try do
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
  end

  defp legacy_port_info(worker_pid) do
    try do
      case GenServer.call(worker_pid, :get_port, 1000) do
        {:ok, port} -> %{current_port: port, requested_port: port}
        _ -> %{current_port: nil, requested_port: nil}
      end
    catch
      :exit, _ -> %{current_port: nil, requested_port: nil}
    end
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
end
