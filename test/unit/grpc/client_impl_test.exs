defmodule Snakepit.GRPC.ClientImplTest do
  use ExUnit.Case, async: true

  alias Google.Protobuf.Any
  alias Snakepit.Bridge
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

  describe "decode_tool_response/1" do
    test "returns binary payload when binary_result is present" do
      response = %Bridge.ExecuteToolResponse{
        success: true,
        result: %Any{
          type_url: "type.googleapis.com/snakepit.tensor.binary",
          value: ~s({"shape":[2],"dtype":"float32"})
        },
        binary_result: <<1, 2, 3>>,
        metadata: %{},
        execution_time_ms: 10
      }

      assert {:ok, {:binary, <<1, 2, 3>>, %{"shape" => [2], "dtype" => "float32"}}} ==
               ClientImpl.decode_tool_response(response)
    end

    test "decodes JSON result when no binary payload exists" do
      response = %Bridge.ExecuteToolResponse{
        success: true,
        result: %Any{
          type_url: "type.googleapis.com/google.protobuf.StringValue",
          value: ~s({"hello":"world"})
        },
        metadata: %{},
        execution_time_ms: 5
      }

      assert {:ok, %{"hello" => "world"}} == ClientImpl.decode_tool_response(response)
    end
  end
end
