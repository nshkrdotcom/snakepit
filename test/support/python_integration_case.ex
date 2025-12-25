defmodule Snakepit.PythonIntegrationCase do
  @moduledoc """
  Test case template for Python integration tests.

  This module ensures the gRPC infrastructure is properly started
  before running Python integration tests.
  """

  use ExUnit.CaseTemplate
  import Snakepit.TestHelpers

  using do
    quote do
      use ExUnit.Case, async: false
      import Snakepit.TestHelpers

      @moduletag :python_integration

      alias Snakepit.Bridge.{Serialization, SessionStore}
      alias Snakepit.GRPC.Client
    end
  end

  setup_all do
    # Temporarily enable pooling to start the gRPC server
    original_pooling = Application.get_env(:snakepit, :pooling_enabled, false)
    original_adapter = Application.get_env(:snakepit, :adapter_module)

    # Don't use pooling, start services manually
    Application.put_env(:snakepit, :pooling_enabled, false)
    Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
    Application.put_env(:snakepit, :grpc_port, 50_051)

    # Stop the application if it's running
    Application.stop(:snakepit)

    # Start the application without pooling
    {:ok, _} = Application.ensure_all_started(:snakepit)

    # Start the services we need manually
    children = [
      # GRPC client supervisor - required for GRPC.Stub.connect() calls
      {GRPC.Client.Supervisor, []},
      # Start the gRPC server
      {GRPC.Server.Supervisor, endpoint: Snakepit.GRPC.Endpoint, port: 50_051, start_server: true}
    ]

    # SessionStore is already started by the application, no need to start it again

    # Start a supervisor for our test services
    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)

    # Wait for gRPC server to be ready
    wait_for_grpc_server()

    # Store supervisor PID for cleanup
    Process.put(:test_supervisor, sup)

    on_exit(fn ->
      # Stop test supervisor if it exists
      if sup = Process.get(:test_supervisor) do
        Supervisor.stop(sup)
      end

      # Restore original configuration
      Application.stop(:snakepit)

      # Wait for processes to actually stop
      assert_eventually(
        fn ->
          Process.whereis(Snakepit.Pool) == nil
        end,
        timeout: 5_000,
        interval: 100
      )

      Application.put_env(:snakepit, :pooling_enabled, original_pooling)
      Application.put_env(:snakepit, :adapter_module, original_adapter)

      # Restart the application with original config for subsequent tests
      {:ok, _} = Application.ensure_all_started(:snakepit)

      # Wait for new pool to be ready
      if original_pooling do
        assert_eventually(
          fn ->
            Snakepit.Pool.await_ready(Snakepit.Pool, 5_000) == :ok
          end,
          timeout: 30_000,
          interval: 1_000
        )
      end
    end)

    {:ok, %{}}
  end

  defp wait_for_grpc_server do
    assert_eventually(
      fn ->
        case GRPC.Stub.connect("localhost:50051") do
          {:ok, channel} ->
            GRPC.Stub.disconnect(channel)
            true

          {:error, _} ->
            false
        end
      end,
      timeout: 10_000,
      interval: 100
    )
  end
end
