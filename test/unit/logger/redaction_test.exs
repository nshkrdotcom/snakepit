defmodule Snakepit.Logger.RedactionTest do
  use ExUnit.Case, async: true

  alias Snakepit.Logger.Redaction

  test "redacts map values while keeping keys" do
    description = Redaction.describe(%{"api_key" => "super_secret"})
    assert description == "map(keys: [\"api_key\"], count: 1)"
  end

  test "summarizes list contents by type" do
    description = Redaction.describe(["token", %{foo: "bar"}, 42])
    assert description == "list(len: 3, sample_types: binary,map,integer)"
  end

  test "summarizes binaries by length" do
    description = Redaction.describe("very secret")
    assert description == "binary(len: 11)"
  end

  test "reports struct name" do
    description = Redaction.describe(%URI{})
    assert description == "struct(URI)"
  end
end
