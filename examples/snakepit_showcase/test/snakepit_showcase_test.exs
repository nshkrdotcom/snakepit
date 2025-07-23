defmodule SnakepitShowcaseTest do
  use ExUnit.Case
  doctest SnakepitShowcase

  test "greets the world" do
    assert SnakepitShowcase.hello() == :world
  end
end