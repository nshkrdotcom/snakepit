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
end
