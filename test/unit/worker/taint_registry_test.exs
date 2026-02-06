defmodule Snakepit.Worker.TaintRegistryTest do
  use ExUnit.Case, async: true

  alias Snakepit.Worker.TaintRegistry

  test "consume_restart enforces single-consumer semantics under concurrency" do
    worker_id = "taint_worker_#{System.unique_integer([:positive])}"
    on_exit(fn -> TaintRegistry.clear_worker(worker_id) end)

    assert :ok = TaintRegistry.taint_worker(worker_id, duration_ms: 10_000, reason: :crash)

    results =
      1..64
      |> Enum.map(fn _ ->
        Task.async(fn -> TaintRegistry.consume_restart(worker_id) end)
      end)
      |> Task.await_many(1_000)

    success_count = Enum.count(results, &match?({:ok, _record}, &1))
    error_count = Enum.count(results, &(&1 == :error))

    assert success_count == 1
    assert error_count == 63
  end
end
