defmodule Snakepit.Internal.TimeoutRunnerTest do
  use ExUnit.Case, async: true

  alias Snakepit.Internal.TimeoutRunner

  test "returns {:ok, result} when function completes in time" do
    assert {:ok, :done} = TimeoutRunner.run(fn -> :done end, 50)
  end

  test "returns :timeout when function exceeds timeout" do
    assert :timeout =
             TimeoutRunner.run(
               fn ->
                 Process.sleep(200)
                 :late
               end,
               10
             )
  end

  test "returns {:error, reason} when function crashes" do
    assert {:error, _reason} =
             TimeoutRunner.run(
               fn ->
                 raise "boom"
               end,
               50
             )
  end
end
