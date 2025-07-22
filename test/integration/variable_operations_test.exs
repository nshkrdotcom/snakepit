defmodule VariableOperationsTest do
  use ExUnit.Case
  import BridgeTestHelper
  
  @moduletag :integration
  
  setup do
    channel = start_bridge()
    session_id = create_test_session(channel)
    
    {:ok, channel: channel, session_id: session_id}
  end
  
  describe "variable CRUD operations" do
    test "register and get variable", %{channel: channel, session_id: session_id} do
      # Register
      {:ok, var_id, variable} = Snakepit.GRPC.Client.register_variable(
        channel,
        session_id,
        "test_var",
        :float,
        3.14,
        metadata: %{"source" => "test"}
      )
      
      assert var_id
      assert variable.name == "test_var"
      assert variable.type == :float
      assert variable.value == 3.14
      
      # Get by name
      {:ok, retrieved} = Snakepit.GRPC.Client.get_variable(
        channel,
        session_id,
        "test_var"
      )
      
      assert retrieved.value == 3.14
      
      # Get by ID
      {:ok, retrieved} = Snakepit.GRPC.Client.get_variable(
        channel,
        session_id,
        var_id
      )
      
      assert retrieved.value == 3.14
    end
    
    test "update variable", %{channel: channel, session_id: session_id} do
      # Register
      {:ok, var_id, _} = Snakepit.GRPC.Client.register_variable(
        channel,
        session_id,
        "mutable_var",
        :integer,
        42
      )
      
      # Update
      :ok = Snakepit.GRPC.Client.set_variable(
        channel,
        session_id,
        "mutable_var",
        100,
        %{"reason" => "test update"}
      )
      
      # Verify
      {:ok, updated} = Snakepit.GRPC.Client.get_variable(
        channel,
        session_id,
        var_id
      )
      
      assert updated.value == 100
      assert updated.version > 1
    end
    
    test "list variables", %{channel: channel, session_id: session_id} do
      # Register multiple
      variables = for i <- 1..5 do
        {:ok, _, var} = Snakepit.GRPC.Client.register_variable(
          channel,
          session_id,
          "var_#{i}",
          :integer,
          i * 10
        )
        var
      end
      
      # List
      {:ok, listed} = Snakepit.GRPC.Client.list_variables(channel, session_id)
      
      assert length(listed) >= 5
      names = Enum.map(listed, & &1.name)
      assert "var_1" in names
      assert "var_5" in names
    end
  end
  
  describe "type constraints" do
    test "validates numeric constraints", %{channel: channel, session_id: session_id} do
      # Register with constraints
      {:ok, _, _} = Snakepit.GRPC.Client.register_variable(
        channel,
        session_id,
        "constrained_float",
        :float,
        0.5,
        constraints: %{min: 0.0, max: 1.0}
      )
      
      # Valid update
      assert :ok = Snakepit.GRPC.Client.set_variable(
        channel,
        session_id,
        "constrained_float",
        0.7
      )
      
      # Invalid update
      assert {:error, _} = Snakepit.GRPC.Client.set_variable(
        channel,
        session_id,
        "constrained_float",
        1.5
      )
    end
    
    test "validates choice constraints", %{channel: channel, session_id: session_id} do
      # Register choice variable
      {:ok, _, _} = Snakepit.GRPC.Client.register_variable(
        channel,
        session_id,
        "model_choice",
        :choice,
        "gpt-4",
        constraints: %{choices: ["gpt-4", "claude-3", "gemini"]}
      )
      
      # Valid choice
      assert :ok = Snakepit.GRPC.Client.set_variable(
        channel,
        session_id,
        "model_choice",
        "claude-3"
      )
      
      # Invalid choice
      assert {:error, _} = Snakepit.GRPC.Client.set_variable(
        channel,
        session_id,
        "model_choice",
        "invalid-model"
      )
    end
  end
end