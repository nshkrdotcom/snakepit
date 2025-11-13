defmodule Snakepit.GRPC.ClientImplTest do
  use ExUnit.Case, async: true

  alias Snakepit.GRPC.ClientImpl

  describe "execute_tool/5 parameter encoding" do
    test "returns structured error when parameters cannot be JSON encoded" do
      result =
        ClientImpl.execute_tool(%{}, "session-123", "noop", %{bad: self()}, timeout: 1000)

      assert {:error, {:invalid_parameter, :json_encode_failed, message}} = result
      assert is_binary(message)
      assert String.contains?(message, "Jason.Encoder")
    end

    test "streaming execution surfaces encoding failures" do
      result =
        ClientImpl.execute_streaming_tool(%{}, "session-123", "noop", %{bad: self()},
          timeout: 1000
        )

      assert {:error, {:invalid_parameter, :json_encode_failed, message}} = result
      assert is_binary(message)
      assert String.contains?(message, "Jason.Encoder")
    end

    test "rejects non-binary entries in binary_parameters" do
      result =
        ClientImpl.execute_tool(
          %{},
          "session-123",
          "noop",
          %{},
          binary_parameters: %{"blob" => 123}
        )

      assert {:error, {:invalid_parameter, "blob", :not_binary}} = result
    end
  end
end
