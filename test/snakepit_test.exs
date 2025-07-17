defmodule SnakepitTest do
  use ExUnit.Case
  doctest Snakepit

  test "Snakepit module exists" do
    assert is_atom(Snakepit)
  end
end
