defmodule SessionStoreTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Test SessionStore functionality independently of gRPC/pool infrastructure.
  """

  test "SessionStore basic operations" do
    session_id = "test_#{System.unique_integer([:positive])}"

    # Create session
    {:ok, session} = Snakepit.Bridge.SessionStore.create_session(session_id)
    assert session.id == session_id
    assert session.metadata == %{}

    # Get session
    assert {:ok, ^session} = Snakepit.Bridge.SessionStore.get_session(session_id)

    # Update session using update function
    {:ok, updated} =
      Snakepit.Bridge.SessionStore.update_session(session_id, fn session ->
        %{session | metadata: %{foo: "bar"}}
      end)

    assert updated.metadata == %{foo: "bar"}

    # Delete session
    :ok = Snakepit.Bridge.SessionStore.delete_session(session_id)
    assert {:error, :not_found} = Snakepit.Bridge.SessionStore.get_session(session_id)
  end

  test "Variable management in SessionStore" do
    session_id = "var_#{System.unique_integer([:positive])}"
    {:ok, _} = Snakepit.Bridge.SessionStore.create_session(session_id)

    # Register integer variable
    {:ok, int_id} =
      Snakepit.Bridge.SessionStore.register_variable(
        session_id,
        "counter",
        :integer,
        0,
        constraints: %{min: 0, max: 100}
      )

    assert is_binary(int_id)

    # Register string variable
    {:ok, str_id} =
      Snakepit.Bridge.SessionStore.register_variable(
        session_id,
        "name",
        :string,
        "test",
        constraints: %{max_length: 50}
      )

    assert is_binary(str_id)

    # Get variables
    {:ok, counter} = Snakepit.Bridge.SessionStore.get_variable(session_id, "counter")
    assert counter.name == "counter"
    assert counter.value == 0
    assert counter.type == :integer

    {:ok, name} = Snakepit.Bridge.SessionStore.get_variable(session_id, "name")
    assert name.name == "name"
    assert name.value == "test"
    assert name.type == :string

    # Update variable
    :ok = Snakepit.Bridge.SessionStore.update_variable(session_id, "counter", 42)

    # Get variable to verify update
    {:ok, updated} = Snakepit.Bridge.SessionStore.get_variable(session_id, "counter")
    assert updated.value == 42

    # List variables
    {:ok, vars} = Snakepit.Bridge.SessionStore.list_variables(session_id)
    assert length(vars) == 2
    assert Enum.any?(vars, &(&1.name == "counter"))
    assert Enum.any?(vars, &(&1.name == "name"))

    # Delete variable
    :ok = Snakepit.Bridge.SessionStore.delete_variable(session_id, "name")
    {:ok, vars} = Snakepit.Bridge.SessionStore.list_variables(session_id)
    assert length(vars) == 1

    # Cleanup
    Snakepit.Bridge.SessionStore.delete_session(session_id)
  end

  test "Variable constraints validation" do
    session_id = "constraints_#{System.unique_integer([:positive])}"
    {:ok, _} = Snakepit.Bridge.SessionStore.create_session(session_id)

    # Register constrained variable
    {:ok, _} =
      Snakepit.Bridge.SessionStore.register_variable(
        session_id,
        "age",
        :integer,
        25,
        constraints: %{min: 0, max: 150}
      )

    # Valid update
    assert :ok = Snakepit.Bridge.SessionStore.update_variable(session_id, "age", 30)
    {:ok, age_var} = Snakepit.Bridge.SessionStore.get_variable(session_id, "age")
    assert age_var.value == 30

    # Invalid update (out of range)
    assert {:error, _} = Snakepit.Bridge.SessionStore.update_variable(session_id, "age", 200)

    # Variable should still have old value
    {:ok, var} = Snakepit.Bridge.SessionStore.get_variable(session_id, "age")
    assert var.value == 30

    # Cleanup
    Snakepit.Bridge.SessionStore.delete_session(session_id)
  end

  test "Session expiration" do
    session_id = "expire_#{System.unique_integer([:positive])}"

    # Create session with very short TTL (0 seconds = immediate expiration)
    {:ok, session} = Snakepit.Bridge.SessionStore.create_session(session_id, ttl: 0)
    assert session.id == session_id

    # Session should exist initially
    assert {:ok, _} = Snakepit.Bridge.SessionStore.get_session(session_id)

    # Wait at least 1 second to ensure time has passed (monotonic time is in seconds)
    Process.sleep(1100)

    # Manually trigger cleanup
    Snakepit.Bridge.SessionStore.cleanup_expired_sessions()

    # Session should now be expired
    assert {:error, :not_found} = Snakepit.Bridge.SessionStore.get_session(session_id)
  end
end
