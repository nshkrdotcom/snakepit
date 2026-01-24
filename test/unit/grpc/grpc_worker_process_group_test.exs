defmodule Snakepit.GRPCWorkerProcessGroupTest do
  use Snakepit.TestCase, async: false

  alias Snakepit.GRPCWorker
  alias Snakepit.Pool.ProcessRegistry
  alias Snakepit.ProcessKiller
  alias Snakepit.TestAdapters.ProcessGroupGRPCAdapter

  defmodule PoolStub do
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:worker_ready, _worker_id}, _from, state) do
      {:reply, :ok, state}
    end
  end

  setup do
    Process.flag(:trap_exit, true)

    ensure_started(Snakepit.Pool.Registry)
    ensure_started(Snakepit.Pool.ProcessRegistry)

    {:ok, pool_pid} = start_supervised(PoolStub)

    python = System.find_executable("python3") || System.find_executable("python")
    sleep_path = System.find_executable("sleep")

    {:ok, pool: pool_pid, python: python, sleep_path: sleep_path}
  end

  @tag :slow
  @tag :integration
  test "records pgid after readiness and kills the whole process group on terminate", %{
    pool: pool_pid,
    python: python,
    sleep_path: sleep_path
  } do
    # ExUnit in this repo doesn't support dynamic skips. Treat missing OS/tooling
    # as a no-op so the suite still runs on non-Unix / minimal environments.
    if ProcessKiller.process_group_supported?() and is_binary(python) and is_binary(sleep_path) do
      prev_process_group_kill = Application.get_env(:snakepit, :process_group_kill)
      Application.put_env(:snakepit, :process_group_kill, true)

      on_exit(fn ->
        if is_nil(prev_process_group_kill) do
          Application.delete_env(:snakepit, :process_group_kill)
        else
          Application.put_env(:snakepit, :process_group_kill, prev_process_group_kill)
        end
      end)

      {worker_id, worker, child_pid_file} =
        start_worker_until_process_group_disabled!(pool_pid, sleep_path, max_attempts: 25)

      on_exit(fn ->
        # Best-effort cleanup if a failure happens mid-test.
        case ProcessRegistry.get_worker_info(worker_id) do
          {:ok, %{process_pid: pid}} when is_integer(pid) ->
            _ = ProcessKiller.kill_with_escalation(pid, 500)
            :ok

          _ ->
            :ok
        end

        File.rm(child_pid_file)
        :ok
      end)

      # After the server signals readiness, Snakepit should re-resolve pgid and persist it.
      assert_eventually(
        fn ->
          case ProcessRegistry.get_worker_info(worker_id) do
            {:ok, %{process_pid: pid, pgid: pgid, process_group?: true}}
            when is_integer(pid) and pid == pgid ->
              true

            _ ->
              false
          end
        end,
        timeout: 10_000,
        interval: 25
      )

      assert_eventually(
        fn -> is_integer(read_child_pid(child_pid_file)) end,
        timeout: 10_000,
        interval: 25
      )

      child_pid = read_child_pid(child_pid_file)

      assert ProcessKiller.process_alive?(child_pid),
             "child pid #{child_pid} should be alive before worker termination"

      :ok = GenServer.stop(worker)

      assert wait_for_death(child_pid, 5_000),
             "child pid #{child_pid} should have died via process-group kill"
    else
      :ok
    end
  end

  defp wait_for_death(pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_death_loop(pid, deadline)
  end

  defp wait_for_death_loop(pid, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      false
    else
      if ProcessKiller.process_alive?(pid) do
        receive do
        after
          50 -> :ok
        end

        wait_for_death_loop(pid, deadline)
      else
        true
      end
    end
  end

  defp ensure_started(child_spec) do
    case start_supervised(child_spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp read_child_pid(path) do
    with {:ok, contents} <- File.read(path),
         {pid, ""} <- Integer.parse(String.trim(contents)),
         true <- pid > 0 do
      pid
    else
      _ -> nil
    end
  end

  defp start_worker_until_process_group_disabled!(pool_pid, sleep_path, opts) do
    max_attempts = Keyword.get(opts, :max_attempts, 10)

    Enum.reduce_while(1..max_attempts, nil, fn _attempt, _acc ->
      worker_id = "process_group_worker_#{System.unique_integer([:positive])}"

      child_pid_file =
        Path.join(System.tmp_dir!(), "snakepit_child_pid_#{System.unique_integer([:positive])}")

      {:ok, worker} =
        GRPCWorker.start_link(
          id: worker_id,
          adapter: ProcessGroupGRPCAdapter,
          pool_name: pool_pid,
          elixir_address: "localhost:0",
          worker_config: %{
            heartbeat: %{enabled: false},
            adapter_env: [
              {"SNAKEPIT_CHILD_PID_FILE", child_pid_file},
              # Give the test a window to read the *initial* registry entry before
              # the worker reaches readiness.
              {"SNAKEPIT_TEST_DELAY_READY_MS", "750"},
              # Avoid the Python-side setsid happening before Snakepit captures pgid.
              {"SNAKEPIT_TEST_DELAY_SETSID_MS", "200"},
              {"SNAKEPIT_TEST_SLEEP_PATH", sleep_path}
            ]
          }
        )

      case ProcessRegistry.get_worker_info(worker_id) do
        {:ok, %{process_group?: false}} ->
          {:halt, {worker_id, worker, child_pid_file}}

        _ ->
          _ = GenServer.stop(worker)
          File.rm(child_pid_file)
          {:cont, nil}
      end
    end)
    |> case do
      {worker_id, worker, child_pid_file} ->
        {worker_id, worker, child_pid_file}

      _ ->
        flunk(
          "failed to start a worker with initial process_group?: false after #{max_attempts} attempts"
        )
    end
  end
end
