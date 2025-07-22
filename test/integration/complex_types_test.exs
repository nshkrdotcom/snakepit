defmodule ComplexTypesTest do
  use ExUnit.Case
  import BridgeTestHelper
  
  @moduletag :integration
  
  setup do
    channel = start_bridge()
    session_id = create_test_session(channel)
    
    {:ok, channel: channel, session_id: session_id}
  end
  
  describe "embedding type" do
    test "stores and retrieves embeddings", %{channel: channel, session_id: session_id} do
      embedding = [0.1, 0.2, 0.3, 0.4, 0.5]
      
      {:ok, _, var} = Snakepit.GRPC.Client.register_variable(
        channel,
        session_id,
        "text_embedding",
        :embedding,
        embedding,
        constraints: %{dimensions: 5}
      )
      
      assert var.value == embedding
      
      # Update with wrong dimensions should fail
      assert {:error, _} = Snakepit.GRPC.Client.set_variable(
        channel,
        session_id,
        "text_embedding",
        [0.1, 0.2]  # Wrong size
      )
    end
  end
  
  describe "tensor type" do
    test "stores and retrieves tensors", %{channel: channel, session_id: session_id} do
      tensor = %{
        "shape" => [2, 3],
        "data" => [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]
      }
      
      {:ok, _, var} = Snakepit.GRPC.Client.register_variable(
        channel,
        session_id,
        "matrix",
        :tensor,
        tensor
      )
      
      assert var.value["shape"] == [2, 3]
      assert List.flatten(var.value["data"]) == [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]
    end
  end
  
  describe "module type" do
    test "stores DSPy module references", %{channel: channel, session_id: session_id} do
      {:ok, _, var} = Snakepit.GRPC.Client.register_variable(
        channel,
        session_id,
        "reasoning_module",
        :module,
        "ChainOfThought",
        constraints: %{choices: ["Predict", "ChainOfThought", "ReAct"]}
      )
      
      assert var.value == "ChainOfThought"
      
      # Can update to another valid module
      :ok = Snakepit.GRPC.Client.set_variable(
        channel,
        session_id,
        "reasoning_module",
        "ReAct"
      )
      
      # Cannot use invalid module
      assert {:error, _} = Snakepit.GRPC.Client.set_variable(
        channel,
        session_id,
        "reasoning_module",
        "InvalidModule"
      )
    end
  end
end