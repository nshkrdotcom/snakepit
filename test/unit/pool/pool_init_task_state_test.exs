defmodule Snakepit.Pool.InitTaskStateTest do
  use ExUnit.Case, async: true

  alias Snakepit.Pool

  test "init-task down message clears tracked init task ref and pid" do
    task_pid =
      spawn(fn ->
        receive do
        end
      end)

    task_ref = Process.monitor(task_pid)

    state = %Pool{
      initializing: true,
      init_task_ref: task_ref,
      init_task_pid: task_pid
    }

    assert {:noreply, new_state} =
             Pool.handle_info({:DOWN, task_ref, :process, task_pid, :normal}, state)

    assert new_state.init_task_ref == nil
    assert new_state.init_task_pid == nil
  end
end
