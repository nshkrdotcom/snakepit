defmodule Snakepit.Pool.ApplicationCleanupTerminateTest do
  use ExUnit.Case, async: true

  alias Snakepit.Pool.ApplicationCleanup

  test "terminate bounds long-running cleanup work" do
    parent = self()
    gate_ref = make_ref()

    slow_cleanup = fn _reason ->
      send(parent, {:cleanup_started, self(), gate_ref})

      receive do
        {:release_cleanup, ^gate_ref} -> :ok
      end
    end

    start_ms = System.monotonic_time(:millisecond)

    assert :ok =
             ApplicationCleanup.terminate(:shutdown, %{
               cleanup_fun: slow_cleanup,
               cleanup_timeout_ms: 40
             })

    elapsed_ms = System.monotonic_time(:millisecond) - start_ms
    assert elapsed_ms < 250

    assert_receive {:cleanup_started, cleanup_pid, ^gate_ref}, 200
    refute Process.alive?(cleanup_pid)
  end

  test "terminate runs cleanup fun when it completes within timeout" do
    parent = self()

    fast_cleanup = fn _reason ->
      send(parent, :cleanup_ran)
      :ok
    end

    assert :ok =
             ApplicationCleanup.terminate(:shutdown, %{
               cleanup_fun: fast_cleanup,
               cleanup_timeout_ms: 200
             })

    assert_receive :cleanup_ran, 100
  end
end
