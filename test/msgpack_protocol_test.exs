defmodule Snakepit.MessagePackProtocolTest do
  use ExUnit.Case, async: true
  alias Snakepit.Bridge.Protocol

  describe "MessagePack encoding/decoding" do
    test "encodes and decodes request with MessagePack" do
      request_id = 123
      command = "test_command"
      args = %{"key" => "value", "number" => 42, "list" => [1, 2, 3]}

      # Encode with MessagePack
      encoded = Protocol.encode_request(request_id, command, args, format: :msgpack)

      # Verify it's binary MessagePack data (not JSON string)
      assert is_binary(encoded)
      # MessagePack is binary, not printable
      refute String.printable?(encoded)

      # Decode with Msgpax to verify structure
      {:ok, decoded} = Msgpax.unpack(encoded)
      assert decoded["id"] == request_id
      assert decoded["command"] == command
      assert decoded["args"] == args
      assert decoded["timestamp"] != nil
    end

    test "decodes MessagePack response correctly" do
      # Create a MessagePack response
      response = %{
        "id" => 456,
        "success" => true,
        "result" => %{"status" => "ok", "data" => [1, 2, 3]},
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      {:ok, msgpack_data} = Msgpax.pack(response, iodata: false)

      # Decode with our protocol
      assert {:ok, 456, %{"status" => "ok", "data" => [1, 2, 3]}} =
               Protocol.decode_response(msgpack_data, format: :msgpack)
    end

    test "handles error responses in MessagePack" do
      response = %{
        "id" => 789,
        "success" => false,
        "error" => "Something went wrong",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      {:ok, msgpack_data} = Msgpax.pack(response, iodata: false)

      assert {:error, 789, "Something went wrong"} =
               Protocol.decode_response(msgpack_data, format: :msgpack)
    end

    test "JSON encoding still works" do
      request_id = 999
      command = "json_test"
      args = %{"format" => "json"}

      # Encode with JSON
      encoded = Protocol.encode_request(request_id, command, args, format: :json)

      # Verify it's a JSON string
      assert is_binary(encoded)
      assert String.printable?(encoded)
      assert String.contains?(encoded, "json_test")

      # Decode JSON response
      json_response =
        ~s({"id":999,"success":true,"result":{"ok":true},"timestamp":"2024-01-01T00:00:00Z"})

      assert {:ok, 999, %{"ok" => true}} = Protocol.decode_response(json_response, format: :json)
    end

    test "protocol negotiation messages use JSON" do
      negotiation_msg = Protocol.encode_protocol_negotiation()

      # Should be JSON
      assert is_binary(negotiation_msg)
      assert String.printable?(negotiation_msg)

      # Should contain expected fields
      {:ok, decoded} = Jason.decode(negotiation_msg)
      assert decoded["type"] == "protocol_negotiation"
      assert "msgpack" in decoded["supported"]
      assert "json" in decoded["supported"]
      assert decoded["preferred"] == "msgpack"
    end

    test "decodes protocol negotiation response" do
      # MessagePack selected
      response = Jason.encode!(%{"type" => "protocol_selected", "protocol" => "msgpack"})
      assert {:ok, :msgpack} = Protocol.decode_protocol_negotiation(response)

      # JSON selected
      response = Jason.encode!(%{"type" => "protocol_selected", "protocol" => "json"})
      assert {:ok, :json} = Protocol.decode_protocol_negotiation(response)

      # Invalid protocol
      response = Jason.encode!(%{"type" => "protocol_selected", "protocol" => "xml"})
      assert {:error, :unsupported_protocol} = Protocol.decode_protocol_negotiation(response)
    end

    test "handles binary data efficiently with MessagePack" do
      # Binary data that would need base64 encoding in JSON
      binary_data = :crypto.strong_rand_bytes(1024)

      args = %{"binary" => binary_data, "type" => "image"}

      # Encode with MessagePack
      encoded = Protocol.encode_request(1, "process_binary", args, format: :msgpack)

      # Decode and verify binary is preserved
      {:ok, decoded} = Msgpax.unpack(encoded)
      assert decoded["args"]["binary"] == binary_data

      # Compare sizes - MessagePack should be more efficient
      json_encoded =
        Protocol.encode_request(
          1,
          "process_binary",
          %{"binary" => Base.encode64(binary_data), "type" => "image"},
          format: :json
        )

      assert byte_size(encoded) < byte_size(json_encoded)
    end
  end
end
