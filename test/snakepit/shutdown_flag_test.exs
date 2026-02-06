defmodule Snakepit.ShutdownFlagTest do
  use ExUnit.Case, async: false

  alias Snakepit.Shutdown
  import Snakepit.TestHelpers, only: [assert_eventually: 2]

  @shutdown_flag_key {Snakepit.Shutdown, :in_progress}

  setup do
    Shutdown.clear_in_progress()

    on_exit(fn ->
      Shutdown.clear_in_progress()
      :persistent_term.put(@shutdown_flag_key, false)
    end)

    :ok
  end

  test "shutdown marker is not sticky after marker owner exits" do
    parent = self()

    marker_pid =
      spawn(fn ->
        Shutdown.mark_in_progress()
        send(parent, :marker_set)
      end)

    assert_receive :marker_set, 500
    marker_ref = Process.monitor(marker_pid)
    assert_receive {:DOWN, ^marker_ref, :process, ^marker_pid, _reason}, 500

    assert_eventually(fn -> not Shutdown.in_progress?() end, timeout: 1_000, interval: 25)
  end

  test "legacy boolean shutdown marker is ignored outside active shutdown" do
    :persistent_term.put(@shutdown_flag_key, true)
    refute Shutdown.in_progress?()
  end
end
