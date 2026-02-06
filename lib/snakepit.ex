defmodule Snakepit do
  @moduledoc """
  Snakepit - A generalized high-performance pooler and session manager.

  Extracted from DSPex V3 pool implementation, Snakepit provides:
  - Concurrent worker initialization and management
  - Stateless pool system with session affinity (hint by default, strict modes available)
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

  alias Snakepit.Logger, as: SLog
  alias Snakepit.Error
  alias Snakepit.Pool.ProcessRegistry
  alias Snakepit.Shutdown
  alias Snakepit.ScriptExit
  alias Snakepit.ScriptStop

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
    * `:affinity` - Override affinity mode (`:hint`, `:strict_queue`, `:strict_fail_fast`)
  """
  @spec execute(command(), args(), keyword()) :: {:ok, result()} | {:error, Snakepit.Error.t()}
  def execute(command, args, opts \\ []) do
    Snakepit.Pool.execute(command, args, opts)
    |> Error.normalize_public_result(%{command: command, pool: opts[:pool] || Snakepit.Pool})
  end

  @doc """
  Executes a command in session context with worker affinity.

  This function executes commands with session-based worker affinity,
  ensuring that subsequent calls with the same session_id prefer
  the same worker when possible for state continuity.

  By default, affinity is a hint: if the preferred worker is busy or tainted,
  the pool can fall back to another worker. To guarantee pinning for in-memory
  refs, configure `affinity: :strict_queue` or `:strict_fail_fast` at the pool level.

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
        handle_chunk(chunk)
      end)

  ## Options

    * `:pool` - The pool to use (default: `Snakepit.Pool`)
    * `:timeout` - Request timeout in ms (default: 300000)
    * `:session_id` - Run in a specific session
    * `:affinity` - Override affinity mode (`:hint`, `:strict_queue`, `:strict_fail_fast`)

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
    cleanup(&Snakepit.RuntimeCleanup.cleanup_current_run/0)
  end

  @doc false
  @spec cleanup((-> :ok | {:timeout, list()})) :: :ok | {:timeout, list()}
  def cleanup(cleanup_fun) when is_function(cleanup_fun, 0) do
    try do
      cleanup_fun.()
    catch
      :exit, {:noproc, _} -> :ok
      :exit, :noproc -> :ok
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
        handle_result(result)
      end)

      # For demos or scripts
      Snakepit.run_as_script(fn ->
        MyApp.run_load_test()
      end)

  ## Options

    * `:timeout` - Maximum time to wait for pool initialization (default: 15000ms)
    * `:shutdown_timeout` - Time to wait for supervisor shutdown confirmation (default: 15000ms)
    * `:cleanup_timeout` - Time to wait for worker process cleanup before forcing cleanup (default: 5000ms).
      When greater than zero, cleanup runs even if Snakepit was already started; set to 0 to skip cleanup.
      Cleanup is bounded; if it exceeds `cleanup_timeout + shutdown margin` the script continues.
    * `:restart` - Restart Snakepit if already started to apply script config (`:auto` | true | false)
    * `:await_pool` - Wait for pool readiness (default: `pooling_enabled` setting)
    * `:exit_mode` - Exit behavior (`:none` | `:halt` | `:stop` | `:auto`, default: `:none`).
      May also be set with `SNAKEPIT_SCRIPT_EXIT`.
    * `:stop_mode` - Stop behavior (`:if_started` | `:always` | `:never`, default: `:if_started`).
    * `:halt` - Legacy boolean for `System.halt/1` after cleanup (default: false,
      or set `SNAKEPIT_SCRIPT_HALT=true`). Ignored when `:exit_mode` is set.

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

    {requested_exit_mode, exit_warnings} =
      ScriptExit.resolve_exit_mode(opts, System.get_env())

    stop_mode = ScriptStop.resolve_stop_mode(opts)

    # Ensure all dependencies are started, including Snakepit itself
    maybe_restart_snakepit(restart, stop_mode, shutdown_timeout, cleanup_timeout)
    {:ok, started_apps} = Application.ensure_all_started(:snakepit)
    owned? = :snakepit in started_apps

    exit_mode = ScriptExit.resolve_auto_exit_mode(requested_exit_mode, owned?)

    ScriptExit.log_warnings(exit_warnings)
    log_exit_mode(requested_exit_mode, exit_mode, owned?)

    beam_run_id = safe_beam_run_id()

    # Deterministically wait for the pool to be fully initialized
    startup_result =
      if await_pool do
        Snakepit.Pool.await_ready(Snakepit.Pool, startup_timeout)
      else
        :ok
      end

    case startup_result do
      :ok ->
        result =
          try do
            {:ok, fun.()}
          catch
            kind, reason ->
              {:error, {kind, reason, __STACKTRACE__}}
          after
            SLog.info(:shutdown, "Script execution finished. Shutting down gracefully.")
          end

        status =
          case result do
            {:ok, _} -> 0
            {:error, _} -> 1
          end

        Shutdown.run(
          exit_mode: exit_mode,
          stop_mode: stop_mode,
          owned?: owned?,
          status: status,
          run_id: beam_run_id,
          shutdown_timeout: shutdown_timeout,
          cleanup_timeout: cleanup_timeout,
          label: "Shutdown"
        )

        case result do
          {:ok, value} ->
            value

          {:error, {kind, reason, stacktrace}} ->
            :erlang.raise(kind, reason, stacktrace)
        end

      {:error, %Snakepit.Error{category: :timeout}} ->
        SLog.error(:startup, "Pool failed to initialize within #{startup_timeout}ms",
          timeout_ms: startup_timeout
        )

        Shutdown.run(
          exit_mode: exit_mode,
          stop_mode: stop_mode,
          owned?: owned?,
          status: 1,
          run_id: beam_run_id,
          shutdown_timeout: shutdown_timeout,
          cleanup_timeout: cleanup_timeout,
          label: "Startup failure"
        )

        {:error, :pool_initialization_timeout}
    end
  end

  defp pooling_enabled? do
    Application.get_env(:snakepit, :pooling_enabled, false)
  end

  defp maybe_restart_snakepit(restart, stop_mode, shutdown_timeout, cleanup_timeout) do
    if snakepit_started?() and should_restart?(restart, stop_mode) do
      SLog.info(:startup, "Restarting to apply script configuration")
      beam_run_id = safe_beam_run_id()
      stop_snakepit(shutdown_timeout, label: "Restart cleanup")
      maybe_cleanup_orphaned_workers(beam_run_id, cleanup_timeout)
    end
  end

  defp should_restart?(true, _stop_mode), do: true
  defp should_restart?(false, _stop_mode), do: false
  defp should_restart?(:auto, :always), do: mix_project_loaded?()
  defp should_restart?(:auto, _stop_mode), do: false
  defp should_restart?(_, _stop_mode), do: false

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

    Shutdown.mark_in_progress()

    try do
      Shutdown.stop_supervisor(Snakepit.Supervisor,
        timeout_ms: shutdown_timeout,
        label: label
      )
    after
      Shutdown.clear_in_progress()
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
      SLog.warning(
        :shutdown,
        "Worker processes still running after #{timeout_ms}ms. Forcing cleanup...",
        timeout_ms: timeout_ms
      )

      Snakepit.ProcessKiller.kill_by_run_id(
        run_id,
        instance_name: Snakepit.Config.instance_name_identifier(),
        allow_missing_instance: not Snakepit.Config.instance_name_configured?(),
        instance_token: Snakepit.Config.instance_token_identifier(),
        allow_missing_token: not Snakepit.Config.instance_token_configured?()
      )

      if not wait_for_run_id_shutdown(run_id, timeout_ms) do
        SLog.warning(:shutdown, "Worker processes still running after forced cleanup.")
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

  defp log_exit_mode(requested_exit_mode, exit_mode, owned?) do
    if requested_exit_mode == exit_mode do
      SLog.info(:shutdown, "Script exit_mode resolved to #{exit_mode}.",
        exit_mode: exit_mode,
        owned?: owned?
      )
    else
      SLog.info(
        :shutdown,
        "Script exit_mode resolved to #{exit_mode} (requested #{requested_exit_mode}).",
        exit_mode: exit_mode,
        requested_exit_mode: requested_exit_mode,
        owned?: owned?
      )
    end
  end
end
