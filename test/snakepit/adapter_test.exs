defmodule Snakepit.AdapterTest do
  use ExUnit.Case, async: true
  alias Snakepit.Adapter

  describe "adapter behavior validation" do
    test "ensures adapter behavior is properly defined" do
      # Verify the behavior exports the required callbacks
      callbacks = Adapter.behaviour_info(:callbacks)
      
      assert {:execute, 3} in callbacks
      assert {:uses_grpc?, 0} in callbacks
      assert {:supports_streaming?, 0} in callbacks
      assert {:init, 1} in callbacks
      assert {:terminate, 2} in callbacks
      assert {:start_worker, 2} in callbacks
    end
  end

  describe "mock adapter implementation" do
    defmodule TestAdapter do
      @behaviour Snakepit.Adapter

      @impl true
      def execute("ping", _args, _opts), do: {:ok, "pong"}
      def execute("error", _args, _opts), do: {:error, "test error"}
      def execute("echo", %{message: msg}, _opts), do: {:ok, msg}
      def execute(cmd, _args, _opts), do: {:error, "Unknown command: #{cmd}"}

      @impl true
      def uses_grpc?, do: false

      @impl true
      def supports_streaming?, do: false

      @impl true
      def init(config), do: {:ok, config}

      @impl true
      def terminate(_reason, _state), do: :ok

      @impl true
      def start_worker(state, worker_id) do
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
      end
    end

    test "adapter implements all required callbacks" do
      assert TestAdapter.execute("ping", %{}, []) == {:ok, "pong"}
      assert TestAdapter.execute("error", %{}, []) == {:error, "test error"}
      assert TestAdapter.execute("echo", %{message: "hello"}, []) == {:ok, "hello"}
      
      assert TestAdapter.uses_grpc? == false
      assert TestAdapter.supports_streaming? == false
      
      assert TestAdapter.init(%{test: true}) == {:ok, %{test: true}}
      assert TestAdapter.terminate(:normal, %{}) == :ok
      
      {:ok, pid} = TestAdapter.start_worker(%{}, "worker_1")
      assert is_pid(pid)
      Process.exit(pid, :kill)
    end
  end

  describe "adapter validation" do
    defmodule InvalidAdapter do
      # Intentionally missing some callbacks
      def execute(_, _, _), do: {:ok, nil}
      def uses_grpc?, do: false
    end

    test "validates adapter implements all required callbacks" do
      # This would be used by pool initialization to validate adapters
      required_callbacks = [
        {:execute, 3},
        {:uses_grpc?, 0},
        {:supports_streaming?, 0},
        {:init, 1},
        {:terminate, 2},
        {:start_worker, 2}
      ]

      # Check that InvalidAdapter is missing callbacks
      exports = InvalidAdapter.__info__(:functions)
      
      missing = Enum.reject(required_callbacks, fn callback ->
        callback in exports
      end)

      assert length(missing) > 0
    end
  end
end