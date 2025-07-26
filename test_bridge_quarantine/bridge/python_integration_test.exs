defmodule Snakepit.Bridge.PythonIntegrationTest do
  @moduledoc """
  Python integration test suite for the Snakepit gRPC bridge.

  This test suite requires Python gRPC workers and tests:
  - gRPC communication (Python <-> Elixir bridge)
  - Cross-language serialization
  - Worker lifecycle management

  To run these tests:
    mix test --include python_integration
  """

  use Snakepit.PythonIntegrationCase

  describe "Full Stack Integration" do
    setup do
      session_id = "integration_test_#{:erlang.unique_integer([:positive])}"
      {:ok, session_id: session_id}
    end

    test "complete variable lifecycle through bridge", %{session_id: session_id} do
      # Get the gRPC channel for real Python integration
      {:ok, channel} = GRPC.Stub.connect("localhost:50051")

      on_exit(fn ->
        GRPC.Stub.disconnect(channel)
      end)

      # Initialize session through the gRPC bridge
      assert {:ok, %{success: true}} = Client.initialize_session(channel, session_id)

      # Register various variable types
      variables = [
        %{name: "int_var", type: :integer, value: 42, constraints: %{min: 0, max: 100}},
        %{name: "float_var", type: :float, value: 3.14, constraints: %{min: 0.0, max: 10.0}},
        %{name: "string_var", type: :string, value: "hello", constraints: %{pattern: "^[a-z]+$"}},
        %{name: "bool_var", type: :boolean, value: true}
      ]

      # Register all variables
      for var <- variables do
        constraints = Map.get(var, :constraints, %{})
        element_type = Map.get(var, :element_type)

        # Build constraints based on type
        constraint_map =
          case var.type do
            :list when not is_nil(element_type) ->
              Map.put(constraints, :element_type, element_type)

            _ ->
              constraints
          end

        assert {:ok, %{success: true}} =
                 Client.register_variable(
                   channel,
                   session_id,
                   var.name,
                   var.type,
                   var.value,
                   constraint_map
                 )
      end

      # List all variables
      assert {:ok, %{variables: listed}} = Client.list_variables(channel, session_id, "*")
      assert length(listed) == length(variables)

      # Get and verify each variable
      for var <- variables do
        assert {:ok, variable} = Client.get_variable(channel, session_id, var.name)
        assert variable.name == var.name
        assert variable.type == var.type
        assert variable.value == var.value
      end

      # Update variables with new values
      updates = [
        %{name: "int_var", value: 50},
        %{name: "float_var", value: 2.71},
        %{name: "string_var", value: "world"}
      ]

      for update <- updates do
        assert {:ok, %{success: true}} =
                 Client.set_variable(
                   channel,
                   session_id,
                   update.name,
                   update.value
                 )
      end

      # Test constraint violations
      # > max
      assert {:error, _} = Client.set_variable(channel, session_id, "int_var", 150)
      # < min
      assert {:error, _} = Client.set_variable(channel, session_id, "float_var", -1.0)
      # pattern mismatch
      assert {:error, _} = Client.set_variable(channel, session_id, "string_var", "CAPS")

      # Test batch operations
      batch_updates = [
        %{identifier: %{name: "int_var"}, value: 75},
        %{identifier: %{name: "bool_var"}, value: false}
      ]

      assert {:ok, %{results: results}} = Client.set_variables(channel, session_id, batch_updates)
      assert length(results) == 2
      assert Enum.all?(results, &(&1.success == true))

      # Delete a variable
      assert {:ok, %{success: true}} = Client.delete_variable(channel, session_id, "bool_var")

      # Verify deletion
      assert {:error, _} = Client.get_variable(channel, session_id, "bool_var")

      # Clean up session
      assert {:ok, %{success: true}} = Client.cleanup_session(channel, session_id)
    end

    test "session isolation and concurrent access", %{session_id: _session_id} do
      {:ok, channel} = GRPC.Stub.connect("localhost:50051")

      on_exit(fn ->
        GRPC.Stub.disconnect(channel)
      end)

      # Create multiple sessions
      sessions =
        for i <- 1..3 do
          "concurrent_session_#{i}"
        end

      # Initialize all sessions
      for session <- sessions do
        assert {:ok, %{success: true}} = Client.initialize_session(channel, session)
      end

      # Register same variable name in different sessions with different values
      for {session, value} <- Enum.zip(sessions, [10, 20, 30]) do
        assert {:ok, %{success: true}} =
                 Client.register_variable(
                   channel,
                   session,
                   "shared_name",
                   :integer,
                   value,
                   %{}
                 )
      end

      # Verify each session has its own value
      for {session, expected} <- Enum.zip(sessions, [10, 20, 30]) do
        assert {:ok, variable} = Client.get_variable(channel, session, "shared_name")
        # The response is the decoded variable based on ClientImpl
        assert variable.value == expected
      end

      # Clean up all sessions
      for session <- sessions do
        assert {:ok, %{success: true}} = Client.cleanup_session(channel, session)
      end
    end

    test "error handling and recovery", %{session_id: session_id} do
      {:ok, channel} = GRPC.Stub.connect("localhost:50051")

      on_exit(fn ->
        GRPC.Stub.disconnect(channel)
      end)

      # Initialize session
      assert {:ok, %{success: true}} = Client.initialize_session(channel, session_id)

      # Test various error conditions

      # 1. Invalid type
      assert {:error, _} =
               Client.register_variable(
                 channel,
                 session_id,
                 "bad_type",
                 :invalid_type,
                 "value",
                 %{}
               )

      # 2. Get non-existent variable
      assert {:error, _} = Client.get_variable(channel, session_id, "non_existent")

      # 3. Invalid session
      assert {:error, _} = Client.get_variable(channel, "invalid_session", "any_var")

      # 4. Type mismatch on update
      assert {:ok, %{success: true}} =
               Client.register_variable(
                 channel,
                 session_id,
                 "typed_var",
                 :integer,
                 42,
                 %{}
               )

      # This should fail because we're trying to set a string value on an integer variable
      result = Client.set_variable(channel, session_id, "typed_var", "string_value")
      assert match?({:error, _}, result)

      # Clean up
      assert {:ok, %{success: true}} = Client.cleanup_session(channel, session_id)
    end

    test "heartbeat and session timeout", %{session_id: session_id} do
      {:ok, channel} = GRPC.Stub.connect("localhost:50051")

      on_exit(fn ->
        GRPC.Stub.disconnect(channel)
      end)

      # Initialize session
      assert {:ok, %{success: true}} = Client.initialize_session(channel, session_id)

      # Send heartbeats
      for _ <- 1..3 do
        assert {:ok, %{success: true}} = Client.heartbeat(channel, session_id)
        Process.sleep(100)
      end

      # Session should still be active
      assert {:ok, %{session: session}} = Client.get_session(channel, session_id)
      assert session.active == true

      # Clean up
      assert {:ok, %{success: true}} = Client.cleanup_session(channel, session_id)
    end
  end

  describe "Type System Integration" do
    setup do
      session_id = "type_test_#{:erlang.unique_integer([:positive])}"
      {:ok, session_id: session_id}
    end

    test "all type serialization roundtrips", %{session_id: session_id} do
      # Test data for each type
      test_cases = [
        # Basic types
        {:integer, 42},
        {:float, 3.14159},
        {:string, "Hello, 世界"},
        {:boolean, true},
        {:boolean, false},

        # Edge cases
        {:integer, 0},
        {:integer, -1},
        {:float, 0.0},
        {:float, -0.0},
        {:string, ""},

        # Large values
        # max int32
        {:integer, 2_147_483_647},
        # near max float64
        {:float, 1.7976931348623157e+308},
        {:string, String.duplicate("a", 1000)}
      ]

      for {type, value} <- test_cases do
        # Initialize session for each test to ensure clean state
        {:ok, _} = SessionStore.create_session(session_id)

        # Create variable with type info
        var_name = "test_#{type}_#{:erlang.unique_integer([:positive])}"

        # No additional constraints needed for basic types
        constraints = %{}

        # Register variable
        assert {:ok, _} =
                 SessionStore.register_variable(
                   session_id,
                   var_name,
                   type,
                   value,
                   constraints
                 )

        # Get it back
        assert {:ok, retrieved} = SessionStore.get_variable(session_id, var_name)
        assert retrieved.value == value
        assert retrieved.type == type

        # Test serialization roundtrip
        assert {:ok, encoded, _binary_data} = Serialization.encode_any(value, type)
        assert {:ok, decoded} = Serialization.decode_any(encoded)
        assert decoded == value

        # Clean up
        SessionStore.delete_session(session_id)
      end
    end
  end

  describe "Performance and Load Testing" do
    @tag :performance
    test "bulk variable operations" do
      session_id = "perf_test_#{:erlang.unique_integer([:positive])}"
      {:ok, _} = SessionStore.create_session(session_id)

      # Register 1000 variables
      start_time = System.monotonic_time(:millisecond)

      for i <- 1..1000 do
        assert {:ok, _} =
                 SessionStore.register_variable(
                   session_id,
                   "var_#{i}",
                   :integer,
                   i,
                   %{min: 0, max: 10000}
                 )
      end

      register_time = System.monotonic_time(:millisecond) - start_time
      assert register_time < 5000, "Registration took too long: #{register_time}ms"

      # List all variables
      start_time = System.monotonic_time(:millisecond)
      assert {:ok, vars} = SessionStore.list_variables(session_id, "*")
      assert length(vars) == 1000
      list_time = System.monotonic_time(:millisecond) - start_time
      assert list_time < 1000, "Listing took too long: #{list_time}ms"

      # Update all variables
      start_time = System.monotonic_time(:millisecond)

      for i <- 1..1000 do
        assert :ok = SessionStore.update_variable(session_id, "var_#{i}", i * 2)
      end

      update_time = System.monotonic_time(:millisecond) - start_time
      assert update_time < 5000, "Updates took too long: #{update_time}ms"

      # Clean up
      SessionStore.delete_session(session_id)
    end

    @tag :performance
    test "concurrent session stress test" do
      # Create 50 concurrent sessions
      sessions = for i <- 1..50, do: "stress_session_#{i}"

      # Run operations in parallel
      tasks =
        for session <- sessions do
          Task.async(fn ->
            {:ok, _} = SessionStore.create_session(session)

            # Each session creates 20 variables
            for j <- 1..20 do
              SessionStore.register_variable(
                session,
                "var_#{j}",
                :integer,
                j * :rand.uniform(100),
                %{}
              )
            end

            # List and verify
            {:ok, vars} = SessionStore.list_variables(session, "*")
            assert length(vars) == 20

            # Clean up
            SessionStore.delete_session(session)
          end)
        end

      # Wait for all tasks with timeout
      results = Task.await_many(tasks, 30_000)
      assert length(results) == 50
    end
  end
end
