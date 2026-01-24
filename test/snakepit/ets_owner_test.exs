defmodule Snakepit.ETSOwnerTest do
  use ExUnit.Case, async: false

  test "owns shared ETS tables" do
    TestHelpers.assert_eventually(fn -> is_pid(Process.whereis(Snakepit.ETSOwner)) end)
    owner = Process.whereis(Snakepit.ETSOwner)

    TestHelpers.assert_eventually(fn -> :ets.whereis(:snakepit_worker_taints) != :undefined end)
    taint_table = :ets.whereis(:snakepit_worker_taints)
    assert :ets.info(taint_table, :owner) == owner

    TestHelpers.assert_eventually(fn ->
      :ets.whereis(:snakepit_zero_copy_handles) != :undefined
    end)

    zero_copy_table = :ets.whereis(:snakepit_zero_copy_handles)
    assert :ets.info(zero_copy_table, :owner) == owner
  end

  test "ensures known tables and rejects unknown ones" do
    assert Snakepit.ETSOwner.ensure_table(:snakepit_worker_taints) == :snakepit_worker_taints

    assert_raise ArgumentError, fn ->
      Snakepit.ETSOwner.ensure_table(:unknown_table)
    end
  end

  test "concurrent ensure_table calls are safe" do
    tasks =
      Enum.map(1..20, fn _ ->
        Task.async(fn -> Snakepit.ETSOwner.ensure_table(:snakepit_zero_copy_handles) end)
      end)

    results = Task.await_many(tasks)
    assert Enum.all?(results, &(&1 == :snakepit_zero_copy_handles))
  end
end
