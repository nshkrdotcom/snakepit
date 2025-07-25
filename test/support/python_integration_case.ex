defmodule Snakepit.PythonIntegrationCase do
  @moduledoc """
  Test case template for Python integration tests.

  This module ensures the gRPC infrastructure is properly started
  before running Python integration tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: false

      @moduletag :python_integration

      alias Snakepit.Bridge.{SessionStore, Serialization}
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
    Application.put_env(:snakepit, :grpc_port, 50051)

    # Stop the application if it's running
    Application.stop(:snakepit)

    # Start the application without pooling
    {:ok, _} = Application.ensure_all_started(:snakepit)

    # Start the services we need manually
    children = [
      # Start the gRPC server
      {GRPC.Server.Supervisor, endpoint: Snakepit.GRPC.Endpoint, port: 50051, start_server: true}
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
      Application.put_env(:snakepit, :pooling_enabled, original_pooling)
      Application.put_env(:snakepit, :adapter_module, original_adapter)

      # Restart the application with original config for subsequent tests
      {:ok, _} = Application.ensure_all_started(:snakepit)
    end)

    {:ok, %{}}
  end

  defp wait_for_grpc_server(retries \\ 50) do
    case GRPC.Stub.connect("localhost:50051") do
      {:ok, channel} ->
        GRPC.Stub.disconnect(channel)
        :ok

      {:error, _} when retries > 0 ->
        Process.sleep(100)
        wait_for_grpc_server(retries - 1)

      {:error, reason} ->
        raise "gRPC server failed to start: #{inspect(reason)}"
    end
  end
end
