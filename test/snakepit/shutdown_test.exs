defmodule Snakepit.ShutdownTest do
  use ExUnit.Case, async: true

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
end
