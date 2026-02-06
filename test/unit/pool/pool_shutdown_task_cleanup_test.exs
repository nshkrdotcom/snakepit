defmodule Snakepit.Pool.ShutdownTaskCleanupTest do
  use Snakepit.TestCase, async: false

  alias Snakepit.Pool

  test "terminate/2 cancels in-flight initialization task" do
    task =
      Task.Supervisor.async_nolink(Snakepit.TaskSupervisor, fn ->
        receive do
        after
          60_000 -> :ok
        end
      end)

    task_pid = task.pid
    ref = Process.monitor(task.pid)
    affinity_cache = :ets.new(:pool_shutdown_task_cleanup_cache, [:set, :private])

    state = %Pool{
      pools: %{},
      affinity_cache: affinity_cache,
      default_pool: :default,
      init_task_ref: task.ref,
      init_task_pid: task.pid
    }

    assert :ok = Pool.terminate(:shutdown, state)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, 1_000
  end
end
