defmodule Snakepit.Worker.ProcessManager do
  @moduledoc false

  alias Snakepit.Logger, as: SLog

  @log_category :grpc

  def spawn_grpc_server(%{
        executable: executable,
        script_path: script_path,
        args: args,
        env_entries: env_entries
      }) do
    {spawn_args, port_opts} = build_port_config(script_path, args)
    port_opts = apply_env_to_port_opts(port_opts, env_entries)

    server_port = Port.open({:spawn_executable, executable}, [{:args, spawn_args} | port_opts])
    Port.monitor(server_port)
    server_port
  end

  def build_port_config(script_path, args) do
    case script_path do
      path when is_binary(path) and byte_size(path) > 0 ->
        {
          [path | args],
          [:binary, :exit_status, :use_stdio, :stderr_to_stdout, {:cd, Path.dirname(path)}]
        }

      _ ->
        {args, [:binary, :exit_status, :use_stdio, :stderr_to_stdout]}
    end
  end

  def wait_for_server_ready(port, ready_file, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_for_server_ready_loop(port, ready_file, deadline, timeout, "")
  end

  def kill_python_process(%{process_pid: nil}, _reason, _graceful_timeout_ms), do: :ok

  def kill_python_process(state, reason, graceful_timeout_ms)
      when reason in [:normal, :shutdown] do
    do_graceful_kill(state, graceful_timeout_ms)
  end

  def kill_python_process(state, {:shutdown, _}, graceful_timeout_ms) do
    do_graceful_kill(state, graceful_timeout_ms)
  end

  def kill_python_process(state, reason, _graceful_timeout_ms) do
    SLog.warning(
      @log_category,
      "Non-graceful termination (#{inspect(reason)}), immediately killing PID #{state.process_pid}"
    )

    result =
      if use_process_group_kill?(state) do
        Snakepit.ProcessKiller.kill_process_group(state.pgid, :sigkill)
      else
        Snakepit.ProcessKiller.kill_process(state.process_pid, :sigkill)
      end

    case result do
      :ok ->
        SLog.debug(@log_category, "✅ Immediately killed gRPC server PID #{state.process_pid}")

      {:error, kill_reason} ->
        SLog.warning(
          @log_category,
          "Failed to kill #{state.process_pid}: #{inspect(kill_reason)}"
        )
    end
  end

  def cleanup_ready_file(path) do
    File.rm(path)
    :ok
  rescue
    _ -> :ok
  end

  def append_startup_output(buffer, output) do
    max_bytes = 4096
    buffer = buffer <> output

    if byte_size(buffer) > max_bytes do
      String.slice(buffer, byte_size(buffer) - max_bytes, max_bytes)
    else
      buffer
    end
  end

  def drain_port_buffer(port, timeout) do
    drain_port_buffer(port, timeout, [])
  end

  defp apply_env_to_port_opts(port_opts, env_entries) when env_entries in [nil, []] do
    port_opts
  end

  defp apply_env_to_port_opts(port_opts, env_entries) do
    env_tuples = Enum.map(env_entries, &to_env_tuple/1)
    port_opts ++ [{:env, env_tuples}]
  end

  defp to_env_tuple({key, value}) do
    {String.to_charlist(key), String.to_charlist(value)}
  end

  defp do_graceful_kill(state, graceful_timeout_ms) do
    SLog.debug(
      @log_category,
      "Starting graceful shutdown of external gRPC process PID: #{state.process_pid}..."
    )

    result =
      if use_process_group_kill?(state) do
        Snakepit.ProcessKiller.kill_process_group_with_escalation(
          state.pgid,
          graceful_timeout_ms
        )
      else
        Snakepit.ProcessKiller.kill_with_escalation(
          state.process_pid,
          graceful_timeout_ms
        )
      end

    case result do
      :ok ->
        SLog.debug(@log_category, "✅ gRPC server PID #{state.process_pid} terminated gracefully")

      {:error, kill_reason} ->
        SLog.warning(
          @log_category,
          "Failed to gracefully kill #{state.process_pid}: #{inspect(kill_reason)}"
        )
    end
  end

  defp use_process_group_kill?(%{process_group?: true, pgid: pgid})
       when is_integer(pgid) do
    Application.get_env(:snakepit, :process_group_kill, true)
  end

  defp use_process_group_kill?(_state), do: false

  defp drain_port_buffer(port, timeout, acc) do
    receive do
      {^port, {:data, data}} ->
        output = to_string(data)
        drain_port_buffer(port, timeout, [output | acc])
    after
      timeout ->
        acc
        |> Enum.reverse()
        |> Enum.join("")
        |> String.trim()
    end
  end

  defp wait_for_server_ready_loop(port, ready_file, deadline, timeout, output_buffer) do
    case read_ready_file(ready_file) do
      {:ok, actual_port} ->
        cleanup_ready_file(ready_file)
        {:ok, actual_port}

      {:error, reason} ->
        cleanup_ready_file(ready_file)
        log_startup_output(output_buffer)
        SLog.error(@log_category, "Failed to read readiness file: #{inspect(reason)}")
        {:error, {:ready_file, reason}}

      :not_ready ->
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        if remaining == 0 do
          cleanup_ready_file(ready_file)
          log_startup_output(output_buffer)

          SLog.error(
            @log_category,
            "Timeout waiting for Python gRPC server to start after #{timeout}ms"
          )

          {:error, :timeout}
        else
          receive do
            {^port, {:data, data}} ->
              output = to_string(data)
              output_buffer = append_startup_output(output_buffer, output)

              if String.trim(output) != "" do
                SLog.debug(
                  @log_category,
                  "Python server output during startup: #{String.trim(output)}"
                )
              end

              wait_for_server_ready_loop(port, ready_file, deadline, timeout, output_buffer)

            {^port, {:exit_status, status}} ->
              cleanup_ready_file(ready_file)

              case status do
                0 ->
                  SLog.debug(
                    @log_category,
                    "Python gRPC server process exited with status 0 during startup (shutdown)"
                  )

                  {:error, :shutdown}

                143 ->
                  SLog.debug(
                    @log_category,
                    "Python gRPC server process exited with status 143 during startup (shutdown)"
                  )

                  {:error, :shutdown}

                _ ->
                  log_startup_output(output_buffer)

                  SLog.error(
                    @log_category,
                    "Python gRPC server process exited with status #{status} during startup"
                  )

                  {:error, {:exit_status, status}}
              end

            {:DOWN, _ref, :port, ^port, reason} ->
              cleanup_ready_file(ready_file)
              log_startup_output(output_buffer)

              SLog.error(
                @log_category,
                "Python gRPC server port died during startup: #{inspect(reason)}"
              )

              {:error, {:port_died, reason}}
          after
            min(remaining, 50) ->
              wait_for_server_ready_loop(port, ready_file, deadline, timeout, output_buffer)
          end
        end
    end
  end

  defp read_ready_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Integer.parse(String.trim(contents)) do
          {port, _} ->
            {:ok, port}

          :error ->
            # Empty or invalid content - file may still be mid-write (atomic rename race)
            # Treat as not ready and keep polling
            :not_ready
        end

      {:error, :enoent} ->
        :not_ready

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp log_startup_output(buffer) do
    trimmed = String.trim(buffer)

    if trimmed != "" do
      SLog.error(@log_category, "Python server output during startup:\n#{trimmed}")
    end
  end
end
