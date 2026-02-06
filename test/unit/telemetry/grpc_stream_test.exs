defmodule Snakepit.Telemetry.GrpcStreamTest do
  use ExUnit.Case, async: true
  import Snakepit.TestHelpers, only: [assert_eventually: 2]

  alias Snakepit.Telemetry.GrpcStream

  test "list_streams tolerates :noproc exits and returns empty list" do
    assert [] ==
             GrpcStream.list_streams(fn ->
               exit({:noproc, {GenServer, :call, [GrpcStream, :list_streams]}})
             end)
  end

  test "terminate/2 drops tracked streams and operations, cancelling timers and tasks" do
    stream_task = spawn(fn -> Process.sleep(:infinity) end)
    stream_task_assert_ref = Process.monitor(stream_task)
    stream_task_ref = Process.monitor(stream_task)

    stream_task_struct = %Task{
      pid: stream_task,
      ref: stream_task_ref,
      owner: self(),
      mfa: {Kernel, :node, []}
    }

    op_task = spawn(fn -> Process.sleep(:infinity) end)
    op_task_assert_ref = Process.monitor(op_task)
    op_task_ref = Process.monitor(op_task)

    stream_open_timer =
      Process.send_after(self(), {:stream_open_timeout, "worker_1", make_ref()}, 100)

    stream_op_timer = Process.send_after(self(), {:stream_op_timeout, op_task_ref}, 100)

    state = %{
      streams: %{
        "worker_1" => %{
          stream: nil,
          task: stream_task_struct,
          worker_ctx: %{worker_id: "worker_1", pool_name: :default, python_pid: nil},
          started_at: System.monotonic_time(),
          connecting?: true,
          pending_controls: [],
          control_ref: nil,
          stream_ref: make_ref(),
          open_timer_ref: stream_open_timer
        }
      },
      ops: %{
        op_task_ref => %{
          kind: :control,
          worker_id: "worker_1",
          metadata: %{action: :toggle},
          task_pid: op_task,
          timer_ref: stream_op_timer
        }
      }
    }

    assert :ok = GrpcStream.terminate(:shutdown, state)

    assert_receive {:DOWN, ^stream_task_assert_ref, :process, ^stream_task, _reason}, 150
    assert_receive {:DOWN, ^op_task_assert_ref, :process, ^op_task, _reason}, 150

    assert_eventually(
      fn ->
        not Process.alive?(stream_task) and not Process.alive?(op_task)
      end,
      timeout: 500,
      interval: 10
    )

    refute_receive {:stream_open_timeout, "worker_1", _}, 150
    refute_receive {:stream_op_timeout, ^op_task_ref}, 150
  end
end
