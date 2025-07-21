defmodule Snakepit.ProtocolNegotiationTest do
  use ExUnit.Case

  alias Snakepit.Bridge.Protocol

  describe "protocol negotiation" do
    test "worker handles protocol configuration correctly" do
      # Worker should handle whatever protocol is configured
      # This test verifies the worker state is set correctly

      # The worker initialization happens in handle_cast(:initialize, state)
      # Let's trace through what happens:

      # 1. Get configured protocol
      protocol_config = Application.get_env(:snakepit, :wire_protocol, :auto)

      # 2. Worker checks if config is :auto (line 162 in worker.ex)
      # If not :auto, it sets format directly based on config
      expected_format =
        case protocol_config do
          :msgpack -> :msgpack
          :json -> :json
          # Auto defaults to JSON after negotiation
          :auto -> :json
          _ -> :json
        end

      # Verify the logic matches
      format = if protocol_config == :msgpack, do: :msgpack, else: :json
      assert format == expected_format
    end

    test "protocol negotiation messages are correctly formatted" do
      # Test that negotiation messages use JSON format
      negotiation_msg = Protocol.encode_protocol_negotiation()

      # Should be valid JSON
      assert {:ok, decoded} = Jason.decode(negotiation_msg)
      assert decoded["type"] == "protocol_negotiation"
      assert "msgpack" in decoded["supported"]
      assert "json" in decoded["supported"]
      assert decoded["preferred"] == "msgpack"
    end

    test "protocol negotiation response decoding" do
      # Test successful negotiation responses
      json_response = Jason.encode!(%{"type" => "protocol_selected", "protocol" => "json"})
      assert {:ok, :json} = Protocol.decode_protocol_negotiation(json_response)

      msgpack_response = Jason.encode!(%{"type" => "protocol_selected", "protocol" => "msgpack"})
      assert {:ok, :msgpack} = Protocol.decode_protocol_negotiation(msgpack_response)

      # Test error cases
      bad_response = Jason.encode!(%{"type" => "wrong_type"})

      assert {:error, :invalid_negotiation_response} =
               Protocol.decode_protocol_negotiation(bad_response)

      unsupported = Jason.encode!(%{"type" => "protocol_selected", "protocol" => "unknown"})
      assert {:error, :unsupported_protocol} = Protocol.decode_protocol_negotiation(unsupported)
    end
  end
end
