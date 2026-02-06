defmodule Snakepit.ShutdownTest do
  use ExUnit.Case, async: true

  alias Snakepit.Shutdown

  defp record(agent, step) do
    Agent.update(agent, &(&1 ++ [step]))
  end

  defp steps(agent) do
    Agent.get(agent, & &1)
  end

  defp base_opts(agent, overrides \\ []) do
    [
      exit_mode: :none,
      stop_mode: :always,
      owned?: true,
      status: 0,
      run_id: "run-123",
      shutdown_timeout: 50,
      cleanup_timeout: 50,
      capture_targets_fun: fn ->
        record(agent, :capture)
        [{:worker, %{process_pid: 1}}]
      end,
      stop_fun: fn _timeout, _label ->
        record(agent, :stop)
        :ok
      end,
      cleanup_fun: fn _targets, _opts ->
        record(agent, :cleanup)
        :ok
      end,
      exit_fun: fn _exit_mode, _status ->
        record(agent, :exit)
        :ok
      end,
      telemetry_fun: fn _event, _measurements, _metadata -> :ok end
    ]
    |> Keyword.merge(overrides)
  end

  test "captures cleanup targets before stopping Snakepit" do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    opts =
      base_opts(agent,
        stop_fun: fn _timeout, _label ->
          record(agent, :stop)
          assert :capture in steps(agent)
          :ok
        end
      )

    Snakepit.Shutdown.run(opts)

    assert steps(agent) == [:capture, :stop, :cleanup, :exit]
  end

  test "orders stop before cleanup and exit" do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    Snakepit.Shutdown.run(base_opts(agent))

    assert steps(agent) == [:capture, :stop, :cleanup, :exit]
  end

  test "cleanup is idempotent across repeated calls" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    cleanup_fun = fn _targets, _opts ->
      Agent.update(agent, &(&1 + 1))
      :ok
    end

    opts = [
      exit_mode: :none,
      stop_mode: :never,
      owned?: false,
      status: 0,
      run_id: "run-123",
      shutdown_timeout: 50,
      cleanup_timeout: 50,
      capture_targets_fun: fn -> [] end,
      stop_fun: fn _timeout, _label -> :ok end,
      cleanup_fun: cleanup_fun,
      exit_fun: fn _exit_mode, _status -> :ok end,
      telemetry_fun: fn _event, _measurements, _metadata -> :ok end
    ]

    Snakepit.Shutdown.run(opts)
    Snakepit.Shutdown.run(opts)

    assert Agent.get(agent, & &1) == 2
  end

  test "cleanup task crashes are normalized and do not crash caller" do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    opts =
      base_opts(agent,
        cleanup_fun: fn _targets, _opts ->
          record(agent, :cleanup)
          raise "cleanup failed"
        end
      )

    assert :ok = Shutdown.run(opts)
    assert steps(agent) == [:capture, :stop, :cleanup, :exit]
  end

  test "stop_supervisor/2 flushes timeout monitor refs" do
    supervisor_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert :ok =
             Shutdown.stop_supervisor(supervisor_pid,
               timeout_ms: 10,
               label: "test-timeout",
               stop_fun: fn -> :ok end
             )

    Process.exit(supervisor_pid, :shutdown)
    refute_receive {:DOWN, _ref, :process, ^supervisor_pid, _reason}, 50
  end

  test "shutdown_reason?/1 matches canonical shutdown reasons" do
    assert Shutdown.shutdown_reason?(:shutdown)
    assert Shutdown.shutdown_reason?({:shutdown, :normal})

    refute Shutdown.shutdown_reason?({:down, :shutdown})
    refute Shutdown.shutdown_reason?(:normal)
    refute Shutdown.shutdown_reason?({:error, :shutdown})
  end
end
