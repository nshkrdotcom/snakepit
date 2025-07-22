defmodule Snakepit.Bridge.SessionTest do
  use ExUnit.Case, async: true

  alias Snakepit.Bridge.Session
  alias Snakepit.Bridge.Variables.Variable

  describe "variable operations" do
    setup do
      session = Session.new("test_session")
      {:ok, session: session}
    end

    test "put and get variable", %{session: session} do
      variable =
        Variable.new(%{
          id: "var_1",
          name: :my_var,
          type: :string,
          value: "hello",
          created_at: System.monotonic_time(:second)
        })

      session = Session.put_variable(session, "var_1", variable)

      # Get by ID
      assert {:ok, fetched} = Session.get_variable(session, "var_1")
      assert fetched.value == "hello"

      # Get by name (string)
      assert {:ok, fetched} = Session.get_variable(session, "my_var")
      assert fetched.value == "hello"

      # Get by name (atom)
      assert {:ok, fetched} = Session.get_variable(session, :my_var)
      assert fetched.value == "hello"
    end

    test "variable not found", %{session: session} do
      assert {:error, :not_found} = Session.get_variable(session, "nonexistent")
      assert {:error, :not_found} = Session.get_variable(session, :nonexistent)
    end

    test "list variables", %{session: session} do
      # Add multiple variables
      vars =
        for i <- 1..3 do
          Variable.new(%{
            id: "var_#{i}",
            name: "var_#{i}",
            type: :integer,
            value: i,
            created_at: System.monotonic_time(:second) + i
          })
        end

      session =
        Enum.reduce(vars, session, fn var, sess ->
          Session.put_variable(sess, var.id, var)
        end)

      listed = Session.list_variables(session)
      assert length(listed) == 3
      assert Enum.map(listed, & &1.value) == [1, 2, 3]
    end

    test "pattern matching", %{session: session} do
      # Add variables with pattern
      vars = [
        Variable.new(%{id: "1", name: "temp_cpu", type: :float, value: 45.0, created_at: 1}),
        Variable.new(%{id: "2", name: "temp_gpu", type: :float, value: 60.0, created_at: 2}),
        Variable.new(%{id: "3", name: "memory_used", type: :integer, value: 1024, created_at: 3})
      ]

      session =
        Enum.reduce(vars, session, fn var, sess ->
          Session.put_variable(sess, var.id, var)
        end)

      # Match pattern
      temps = Session.list_variables(session, "temp_*")
      assert length(temps) == 2
      assert Enum.all?(temps, fn v -> String.starts_with?(to_string(v.name), "temp_") end)
    end

    test "session stats", %{session: session} do
      assert session.stats.variable_count == 0

      # Add variable
      var =
        Variable.new(%{
          id: "var_1",
          name: :test,
          type: :integer,
          value: 1,
          created_at: 1
        })

      session = Session.put_variable(session, "var_1", var)
      assert session.stats.variable_count == 1
      assert session.stats.total_variable_updates == 1

      # Update variable
      updated_var = Variable.update_value(var, 2)
      session = Session.put_variable(session, "var_1", updated_var)
      assert session.stats.variable_count == 1
      assert session.stats.total_variable_updates == 2
    end

    test "delete variable", %{session: session} do
      var =
        Variable.new(%{
          id: "var_del",
          name: :deletable,
          type: :string,
          value: "delete me",
          created_at: 1
        })

      session = Session.put_variable(session, "var_del", var)
      assert session.stats.variable_count == 1

      # Delete by ID
      session = Session.delete_variable(session, "var_del")
      assert session.stats.variable_count == 0
      assert {:error, :not_found} = Session.get_variable(session, "var_del")

      # Add again
      session = Session.put_variable(session, "var_del", var)

      # Delete by name
      session = Session.delete_variable(session, :deletable)
      assert session.stats.variable_count == 0
    end

    test "has_variable?", %{session: session} do
      var =
        Variable.new(%{
          id: "var_exists",
          name: :exists,
          type: :boolean,
          value: true,
          created_at: 1
        })

      session = Session.put_variable(session, "var_exists", var)

      assert Session.has_variable?(session, "var_exists")
      assert Session.has_variable?(session, :exists)
      assert Session.has_variable?(session, "exists")
      refute Session.has_variable?(session, "nope")
    end

    test "variable_names", %{session: session} do
      vars = [
        Variable.new(%{id: "1", name: :alpha, type: :integer, value: 1, created_at: 1}),
        Variable.new(%{id: "2", name: "beta", type: :integer, value: 2, created_at: 2}),
        Variable.new(%{id: "3", name: :gamma, type: :integer, value: 3, created_at: 3})
      ]

      session =
        Enum.reduce(vars, session, fn var, sess ->
          Session.put_variable(sess, var.id, var)
        end)

      names = Session.variable_names(session)
      assert length(names) == 3
      assert Enum.sort(names) == ["alpha", "beta", "gamma"]
    end

    test "get_stats includes all metrics", %{session: session} do
      # Add a variable and a program
      var =
        Variable.new(%{
          id: "var_stats",
          name: :stats_test,
          type: :integer,
          value: 42,
          created_at: System.monotonic_time(:second)
        })

      session =
        session
        |> Session.put_variable("var_stats", var)
        |> Session.put_program("prog_1", %{name: "test_program"})

      stats = Session.get_stats(session)

      assert stats.variable_count == 1
      assert stats.program_count == 1
      assert stats.total_items == 2
      assert stats.total_variable_updates == 1
      assert is_integer(stats.age)
      assert is_integer(stats.time_since_access)
    end
  end

  describe "backward compatibility" do
    test "programs still work with new structure" do
      session = Session.new("back_compat")

      # Add program
      session = Session.put_program(session, "prog_1", %{code: "print('hello')"})
      assert session.stats.program_count == 1

      # Get program
      assert {:ok, prog} = Session.get_program(session, "prog_1")
      assert prog.code == "print('hello')"

      # Delete program
      session = Session.delete_program(session, "prog_1")
      assert {:error, :not_found} = Session.get_program(session, "prog_1")
    end

    test "metadata operations still work" do
      session = Session.new("meta_test")

      session = Session.put_metadata(session, :user_id, "user_123")
      assert Session.get_metadata(session, :user_id) == "user_123"
      assert Session.get_metadata(session, :missing, "default") == "default"
    end
  end

  describe "edge cases" do
    test "variable with atom name works correctly" do
      session = Session.new("atom_test")

      var =
        Variable.new(%{
          id: "var_atom",
          # atom name
          name: :temperature,
          type: :float,
          value: 0.7,
          created_at: 1
        })

      session = Session.put_variable(session, "var_atom", var)

      # Both string and atom lookup should work
      assert {:ok, found} = Session.get_variable(session, "temperature")
      assert found.value == 0.7

      assert {:ok, found} = Session.get_variable(session, :temperature)
      assert found.value == 0.7
    end

    test "updating same variable multiple times" do
      session = Session.new("update_test")

      var =
        Variable.new(%{
          id: "var_update",
          name: :counter,
          type: :integer,
          value: 0,
          created_at: 1
        })

      session = Session.put_variable(session, "var_update", var)

      # Update multiple times
      Enum.reduce(1..5, session, fn i, sess ->
        updated_var = Variable.update_value(var, i)
        updated_sess = Session.put_variable(sess, "var_update", updated_var)

        # Verify stats
        assert updated_sess.stats.variable_count == 1
        assert updated_sess.stats.total_variable_updates == i + 1

        updated_sess
      end)
    end
  end
end
