defmodule Snakepit.Worker.ProcessManagerTest do
  use ExUnit.Case, async: true

  alias Snakepit.Worker.ProcessManager

  test "wait_for_server_ready stops on shutdown exit" do
    ready_file =
      Path.join(System.tmp_dir!(), "snakepit_ready_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(ready_file) end)

    parent = self()

    pid =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        result = ProcessManager.wait_for_server_ready(make_ref(), ready_file, 5_000)
        send(parent, {:wait_result, result})
      end)

    send(pid, {:EXIT, self(), :shutdown})

    assert_receive {:wait_result, {:error, :shutdown}}, 1_000
  end
end
