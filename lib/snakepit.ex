defmodule Snakepit do
  @moduledoc """
  Snakepit - A generalized high-performance pooler and session manager.

  Extracted from DSPex V3 pool implementation, Snakepit provides:
  - Concurrent worker initialization and management
  - Stateless pool system with session affinity
  - Generalized adapter pattern for any external process
  - High-performance OTP-based process management

  ## Basic Usage

      # Configure in config/config.exs
      config :snakepit,
        pooling_enabled: true,
        adapter_module: YourAdapter

      # Execute commands on any available worker
      {:ok, result} = Snakepit.execute("ping", %{test: true})

      # Session-based execution with worker affinity
      {:ok, result} = Snakepit.execute_in_session("my_session", "command", %{})
  """

  alias Snakepit.Pool.ProcessRegistry

  # Type definitions
  @type command :: String.t()
  @type args :: map()
  @type result :: term()
  @type session_id :: String.t()
  @type callback_fn :: (term() -> any())
  @type pool_name :: atom() | pid()

  @doc """
  Convenience function to execute commands on the pool.

  ## Examples

      {:ok, result} = Snakepit.execute("ping", %{test: true})

  ## Options

    * `:pool` - The pool to use (default: `Snakepit.Pool`)
    * `:timeout` - Request timeout in ms (default: 60000)
    * `:session_id` - Execute with session affinity
  """
  @spec execute(command(), args(), keyword()) :: {:ok, result()} | {:error, Snakepit.Error.t()}
  def execute(command, args, opts \\ []) do
    Snakepit.Pool.execute(command, args, opts)
  end

  @doc """
  Executes a command in session context with worker affinity.

  This function executes commands with session-based worker affinity,
  ensuring that subsequent calls with the same session_id prefer
  the same worker when possible for state continuity.

  Args are passed through unchanged - no domain-specific enhancement.
  """
  @spec execute_in_session(session_id(), command(), args(), keyword()) ::
          {:ok, result()} | {:error, Snakepit.Error.t()}
  def execute_in_session(session_id, command, args, opts \\ []) do
    # Add session_id to opts for session affinity
    opts_with_session = Keyword.put(opts, :session_id, session_id)

    # Execute command with session affinity (no args enhancement)
    execute(command, args, opts_with_session)
  end

  @doc """
  Get pool statistics.

  Returns aggregate stats across all pools or stats for a specific pool.
  """
  @spec get_stats(pool_name()) :: map()
  def get_stats(pool \\ Snakepit.Pool) do
    Snakepit.Pool.get_stats(pool)
  end

  @doc """
  List workers from the pool.

  Returns a list of worker IDs.
  """
  @spec list_workers(pool_name()) :: [String.t()]
  def list_workers(pool \\ Snakepit.Pool) do
    Snakepit.Pool.list_workers(pool)
  end

  @doc """
  Executes a streaming command with a callback function.

  ## Examples

      Snakepit.execute_stream("batch_inference", %{items: [...]}, fn chunk ->
        IO.puts("Received: \#{inspect(chunk)}")
      end)

  ## Options

    * `:pool` - The pool to use (default: `Snakepit.Pool`)
    * `:timeout` - Request timeout in ms (default: 300000)
    * `:session_id` - Run in a specific session

  ## Returns

  Returns `:ok` on success or `{:error, %Snakepit.Error{}}` on failure.

  Note: Streaming is only supported with gRPC adapters.
  """
  @spec execute_stream(command(), args(), callback_fn(), keyword()) ::
          :ok | {:error, Snakepit.Error.t()}
  def execute_stream(command, args \\ %{}, callback_fn, opts \\ []) do
    ensure_started!()

    adapter = Application.get_env(:snakepit, :adapter_module)

    if function_exported?(adapter, :uses_grpc?, 0) and adapter.uses_grpc?() do
      Snakepit.Pool.execute_stream(command, args, callback_fn, opts)
    else
      {:error,
       Snakepit.Error.validation_error("Streaming not supported by adapter", %{
         adapter: adapter
       })}
    end
  end

  @doc """
  Manually trigger cleanup of external worker processes for the current run.

  Useful for library embedding or scripts that control the lifecycle directly.
  """
  @spec cleanup() :: :ok | {:timeout, list()}
  def cleanup do
    if Process.whereis(Snakepit.Pool.ProcessRegistry) do
      Snakepit.RuntimeCleanup.cleanup_current_run()
    else
      :ok
    end
  end

  @doc """
  Executes a command in a session with a callback function.
  """
  @spec execute_in_session_stream(session_id(), command(), args(), callback_fn(), keyword()) ::
          :ok | {:error, Snakepit.Error.t()}
  def execute_in_session_stream(session_id, command, args \\ %{}, callback_fn, opts \\ []) do
    ensure_started!()

    adapter = Application.get_env(:snakepit, :adapter_module)

    if function_exported?(adapter, :uses_grpc?, 0) and adapter.uses_grpc?() do
      opts_with_session = Keyword.put(opts, :session_id, session_id)
      Snakepit.Pool.execute_stream(command, args, callback_fn, opts_with_session)
    else
      {:error,
       Snakepit.Error.validation_error("Streaming not supported by adapter", %{
         adapter: adapter
       })}
    end
  end

  defp ensure_started! do
    case Application.ensure_all_started(:snakepit) do
      {:ok, _} -> :ok
      {:error, _} -> raise "Snakepit application not started"
    end
  end

  @doc """
  Starts the Snakepit application, executes a given function,
  and ensures graceful shutdown.

  This is the recommended way to use Snakepit for short-lived scripts or
  Mix tasks to prevent orphaned processes.

  It handles the full OTP application lifecycle (start, run, stop)
  automatically.

  ## Examples

      # In a Mix task
      Snakepit.run_as_script(fn ->
        {:ok, result} = Snakepit.execute("my_command", %{data: "value"})
        IO.inspect(result)
      end)

      # For demos or scripts
      Snakepit.run_as_script(fn ->
        MyApp.run_load_test()
      end)

  ## Options

    * `:timeout` - Maximum time to wait for pool initialization (default: 15000ms)
    * `:shutdown_timeout` - Time to wait for supervisor shutdown confirmation (default: 15000ms)
    * `:cleanup_timeout` - Time to wait for worker process cleanup before forcing cleanup (default: 5000ms)
      (cleanup is bounded; if it exceeds `cleanup_timeout + 1000` ms the script continues)
    * `:restart` - Restart Snakepit if already started to apply script config (`:auto` | true | false)
    * `:await_pool` - Wait for pool readiness (default: `pooling_enabled` setting)
    * `:halt` - Force `System.halt/1` after cleanup for scripts that must exit (default: false,
      or set `SNAKEPIT_SCRIPT_HALT=true`)

  ## Returns

  Returns the result of the provided function, or `{:error, reason}` if
  the pool fails to initialize.
  """
  @spec run_as_script((-> any()), keyword()) :: any() | {:error, term()}
  def run_as_script(fun, opts \\ []) when is_function(fun, 0) do
    startup_timeout = Keyword.get(opts, :timeout, 15_000)
    shutdown_timeout = Keyword.get(opts, :shutdown_timeout, 15_000)
    cleanup_timeout = Keyword.get(opts, :cleanup_timeout, 5_000)
    restart = Keyword.get(opts, :restart, :auto)
    await_pool = Keyword.get(opts, :await_pool, pooling_enabled?())
    halt = Keyword.get(opts, :halt, env_truthy?("SNAKEPIT_SCRIPT_HALT"))

    # Ensure all dependencies are started, including Snakepit itself
    maybe_restart_snakepit(restart, shutdown_timeout, cleanup_timeout)
    {:ok, _apps} = Application.ensure_all_started(:snakepit)

    # Deterministically wait for the pool to be fully initialized
    startup_result =
      if await_pool do
        Snakepit.Pool.await_ready(Snakepit.Pool, startup_timeout)
      else
        :ok
      end

    case startup_result do
      :ok ->
        beam_run_id = safe_beam_run_id()

        result =
          try do
            {:ok, fun.()}
          catch
            kind, reason ->
              {:error, {kind, reason, __STACKTRACE__}}
          after
            IO.puts("\n[Snakepit] Script execution finished. Shutting down gracefully...")

            stop_snakepit(shutdown_timeout, label: "Shutdown")
            run_cleanup_with_timeout(beam_run_id, cleanup_timeout)
          end

        case result do
          {:ok, value} ->
            maybe_halt(halt, 0)
            value

          {:error, {kind, reason, stacktrace}} ->
            maybe_halt(halt, 1)
            :erlang.raise(kind, reason, stacktrace)
        end

      {:error, %Snakepit.Error{category: :timeout}} ->
        IO.puts("[Snakepit] Error: Pool failed to initialize within #{startup_timeout}ms")
        Application.stop(:snakepit)
        maybe_halt(halt, 1)
        {:error, :pool_initialization_timeout}
    end
  end

  defp pooling_enabled? do
    Application.get_env(:snakepit, :pooling_enabled, false)
  end

  defp maybe_restart_snakepit(restart, shutdown_timeout, cleanup_timeout) do
    if should_restart?(restart) and snakepit_started?() do
      IO.puts("[Snakepit] Restarting to apply script configuration...")
      beam_run_id = safe_beam_run_id()
      stop_snakepit(shutdown_timeout, label: "Restart cleanup")
      maybe_cleanup_orphaned_workers(beam_run_id, cleanup_timeout)
    end
  end

  defp should_restart?(true), do: true
  defp should_restart?(false), do: false
  defp should_restart?(:auto), do: mix_project_loaded?()
  defp should_restart?(_), do: false

  defp mix_project_loaded? do
    mix_started? =
      Enum.any?(Application.started_applications(), fn {app, _desc, _vsn} ->
        app == :mix
      end)

    if mix_started? and Code.ensure_loaded?(Mix.Project) and
         function_exported?(Mix.Project, :get, 0) do
      try do
        Mix.Project.get() != nil
      catch
        _, _ -> false
      end
    else
      false
    end
  end

  defp snakepit_started? do
    Enum.any?(Application.started_applications(), fn {app, _desc, _vsn} ->
      app == :snakepit
    end)
  end

  defp stop_snakepit(shutdown_timeout, opts) do
    label = Keyword.get(opts, :label, "Shutdown")

    # Monitor the supervisor to wait for actual shutdown signal
    case Process.whereis(Snakepit.Supervisor) do
      nil ->
        Application.stop(:snakepit)
        # Already shut down
        IO.puts("[Snakepit] #{label} complete (supervisor already terminated).")

      supervisor_pid ->
        ref = Process.monitor(supervisor_pid)
        Application.stop(:snakepit)

        # Wait for :DOWN signal from BEAM - no guessing with sleep
        receive do
          {:DOWN, ^ref, :process, ^supervisor_pid, _reason} ->
            IO.puts("[Snakepit] #{label} complete (confirmed via :DOWN signal).")
        after
          shutdown_timeout ->
            IO.puts(
              "[Snakepit] Warning: #{label} confirmation timeout after #{shutdown_timeout}ms. " <>
                "Proceeding anyway."
            )
        end
    end
  end

  defp safe_beam_run_id do
    ProcessRegistry.get_beam_run_id()
  catch
    _, _ -> nil
  end

  defp maybe_cleanup_orphaned_workers(nil, _timeout_ms), do: :ok
  defp maybe_cleanup_orphaned_workers(_run_id, timeout_ms) when timeout_ms <= 0, do: :ok

  defp maybe_cleanup_orphaned_workers(run_id, timeout_ms) do
    if wait_for_run_id_shutdown(run_id, timeout_ms) do
      :ok
    else
      IO.puts(
        "[Snakepit] Warning: Worker processes still running after #{timeout_ms}ms. " <>
          "Forcing cleanup..."
      )

      Snakepit.ProcessKiller.kill_by_run_id(run_id)

      if not wait_for_run_id_shutdown(run_id, timeout_ms) do
        IO.puts("[Snakepit] Warning: Worker processes still running after forced cleanup.")
      end
    end
  end

  defp wait_for_run_id_shutdown(run_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_run_id_shutdown_loop(run_id, deadline)
  end

  defp wait_for_run_id_shutdown_loop(run_id, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      false
    else
      if run_id_processes?(run_id) do
        receive do
        after
          100 -> :ok
        end

        wait_for_run_id_shutdown_loop(run_id, deadline)
      else
        true
      end
    end
  end

  defp run_id_processes?(run_id) do
    Snakepit.ProcessKiller.find_python_processes()
    |> Enum.any?(fn pid ->
      case Snakepit.ProcessKiller.get_process_command(pid) do
        {:ok, cmd} -> run_id_in_command?(cmd, run_id)
        _ -> false
      end
    end)
  end

  defp run_id_in_command?(command, run_id) do
    has_script =
      String.contains?(command, "grpc_server.py") or
        String.contains?(command, "grpc_server_threaded.py")

    has_run_id =
      String.contains?(command, "--snakepit-run-id #{run_id}") or
        String.contains?(command, "--run-id #{run_id}")

    has_script and has_run_id
  end

  defp run_cleanup_with_timeout(run_id, cleanup_timeout) do
    if cleanup_timeout <= 0 or is_nil(run_id) do
      maybe_cleanup_orphaned_workers(run_id, cleanup_timeout)
    else
      task_timeout = cleanup_timeout + 1_000
      task = Task.async(fn -> maybe_cleanup_orphaned_workers(run_id, cleanup_timeout) end)

      case Task.yield(task, task_timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, _} ->
          :ok

        nil ->
          IO.puts(
            "[Snakepit] Warning: cleanup exceeded #{task_timeout}ms. Skipping remaining cleanup."
          )

        {:exit, reason} ->
          IO.puts("[Snakepit] Warning: cleanup crashed: #{inspect(reason)}")
      end
    end
  end

  defp maybe_halt(true, status) do
    if status != 0 do
      IO.puts("[Snakepit] Halting BEAM with status #{status}.")
    end

    # Flush all IO before halting to ensure output is visible
    :ok = :io.put_chars(:standard_io, [])
    :ok = :io.put_chars(:standard_error, [])

    System.halt(status)
  end

  defp maybe_halt(_, _status), do: :ok

  defp env_truthy?(name) do
    case System.get_env(name) do
      nil -> false
      value -> String.downcase(String.trim(value)) in ["1", "true", "yes", "y", "on"]
    end
  end
end
