defmodule Snakepit.ScriptExitIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :slow

  @script_path Path.expand("../support/scripts/script_exit.exs", __DIR__)
  @project_root Path.expand("../..", __DIR__)

  test "exit_mode halt exits with status 0 on normal return" do
    {_output, status} = run_script(["--exit-mode", "halt"])

    assert status == 0
  end

  test "exit_mode halt exits with status 1 on exception" do
    {_output, status} = run_script(["--exit-mode", "halt", "--raise"])

    assert status == 1
  end

  test "exit_mode stop exits with status 0 on normal return" do
    {_output, status} = run_script(["--exit-mode", "stop"], no_halt: true)

    assert status == 0
  end

  test "exit_mode stop exits with status 1 on exception" do
    {_output, status} = run_script(["--exit-mode", "stop", "--raise"], no_halt: true)

    assert status == 1
  end

  test "broken pipe does not hang exit path" do
    run_with_broken_pipe(["--exit-mode", "halt", "--print-ready"], timeout_ms: 10_000)
  end

  defp run_script(args, opts \\ []) do
    no_halt = Keyword.get(opts, :no_halt, false)
    timeout_ms = Keyword.get(opts, :timeout_ms, 10_000)
    env = Keyword.get(opts, :env, %{})

    mix_args = build_mix_args(no_halt, args)

    task =
      Task.async(fn ->
        System.cmd("mix", mix_args,
          cd: @project_root,
          env: Map.to_list(env),
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        flunk("mix run timed out after #{timeout_ms}ms")

      {:exit, reason} ->
        flunk("mix run crashed: #{inspect(reason)}")
    end
  end

  defp run_with_broken_pipe(args, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 10_000)
    env = Keyword.get(opts, :env, %{})

    mix_path = System.find_executable("mix")
    kill_path = System.find_executable("kill")

    if is_nil(mix_path) or is_nil(kill_path) do
      flunk("mix or kill not available for broken pipe test")
    end

    port =
      Port.open({:spawn_executable, mix_path}, [
        :binary,
        :stderr_to_stdout,
        args: build_mix_args(false, args),
        cd: @project_root,
        env: Map.to_list(env)
      ])

    wait_for_marker(port, "SCRIPT_READY", timeout_ms)

    {:os_pid, pid} = Port.info(port, :os_pid)
    Port.close(port)

    wait_for_exit(pid, kill_path, timeout_ms)
  end

  defp build_mix_args(no_halt, script_args) do
    base = ["run"]
    base = if no_halt, do: base ++ ["--no-halt"], else: base
    # Mix expects script args directly after the file (no `--` separator).
    base ++ [@script_path] ++ script_args
  end

  defp wait_for_marker(port, marker, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_marker_loop(port, marker, deadline, "")
  end

  defp wait_for_marker_loop(port, marker, deadline, buffer) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      flunk("timed out waiting for marker #{marker}")
    end

    receive do
      {^port, {:data, data}} ->
        new_buffer = buffer <> data

        if String.contains?(new_buffer, marker) do
          :ok
        else
          wait_for_marker_loop(port, marker, deadline, new_buffer)
        end
    after
      remaining ->
        flunk("timed out waiting for marker #{marker}")
    end
  end

  defp wait_for_exit(pid, kill_path, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_exit_loop(pid, kill_path, deadline)
  end

  defp wait_for_exit_loop(pid, kill_path, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      flunk("process #{pid} did not exit after pipe close")
    end

    {_output, status} =
      System.cmd(kill_path, ["-0", Integer.to_string(pid)], stderr_to_stdout: true)

    if status == 0 do
      receive do
      after
        50 -> :ok
      end

      wait_for_exit_loop(pid, kill_path, deadline)
    else
      :ok
    end
  end
end
