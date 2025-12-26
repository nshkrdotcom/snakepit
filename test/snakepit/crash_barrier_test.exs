defmodule Snakepit.CrashBarrierTest do
  use ExUnit.Case, async: true

  alias Snakepit.CrashBarrier
  alias Snakepit.Worker.TaintRegistry

  test "taints workers on classified crash" do
    config = CrashBarrier.config(%{crash_barrier: %{enabled: true}})

    assert {:ok, info} =
             CrashBarrier.crash_info({:error, {:worker_exit, {:grpc_server_exited, 139}}}, config)

    worker_id = "crash_worker_#{System.unique_integer([:positive])}"

    on_exit(fn -> TaintRegistry.clear_worker(worker_id) end)

    CrashBarrier.taint_worker(:default, worker_id, info, config)
    assert CrashBarrier.worker_tainted?(worker_id)
  end

  test "retries only idempotent calls when configured" do
    config = CrashBarrier.config(%{crash_barrier: %{enabled: true, retry: :idempotent}})

    assert CrashBarrier.retry_allowed?(config, true, 0)
    refute CrashBarrier.retry_allowed?(config, false, 0)
    refute CrashBarrier.retry_allowed?(config, true, 1)
  end
end
