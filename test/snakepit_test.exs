defmodule SnakepitTest do
  use ExUnit.Case
  doctest Snakepit

  test "Snakepit module exists" do
    assert is_atom(Snakepit)
  end

  test "cleanup tolerates :noproc exits and remains idempotent" do
    assert :ok =
             Snakepit.cleanup(fn ->
               exit({:noproc, {GenServer, :call, [Snakepit.Pool.ProcessRegistry, :any]}})
             end)
  end
end
