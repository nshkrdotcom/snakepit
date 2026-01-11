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
    original_env = capture_env()

    try do
      # Don't use pooling, start services manually
      Application.put_env(:snakepit, :pooling_enabled, false)
      Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
      Application.delete_env(:snakepit, :grpc_port)
      Application.put_env(:snakepit, :grpc_listener, %{mode: :internal})

      # Stop the application if it's running
      Application.stop(:snakepit)

      # Start the application without pooling
      {:ok, _} = Application.ensure_all_started(:snakepit)

      # Start the services we need manually
      children = [
        # GRPC client supervisor - required for GRPC.Stub.connect() calls
        Snakepit.GRPC.ClientSupervisor,
        # Start the gRPC listener (ephemeral port, multi-instance safe)
        Snakepit.GRPC.Listener
      ]

      # SessionStore is already started by the application, no need to start it again

      # Start a supervisor for our test services
      case Supervisor.start_link(children, strategy: :one_for_one) do
        {:ok, sup} ->
          # Wait for gRPC server to be ready
          {:ok, info} = Snakepit.GRPC.Listener.await_ready(10_000)
          address = "#{info.host}:#{info.port}"
          wait_for_grpc_server(address)

          # Store supervisor PID for cleanup
          Process.put(:test_supervisor, sup)

          on_exit(fn -> restore_env(original_env) end)

          {:ok, %{grpc_address: address}}

        {:error, reason} ->
          restore_env(original_env)
          raise "Failed to start test supervisor: #{inspect(reason)}"
      end
    rescue
      error ->
        restore_env(original_env)
        reraise error, __STACKTRACE__
    catch
      :exit, reason ->
        restore_env(original_env)
        exit(reason)
    end
  end

  defp wait_for_grpc_server(address) do
    assert_eventually(
      fn ->
        case GRPC.Stub.connect(address) do
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

  defp capture_env do
    %{
      pooling_enabled: Application.get_env(:snakepit, :pooling_enabled, false),
      adapter_module: Application.get_env(:snakepit, :adapter_module),
      grpc_port: Application.get_env(:snakepit, :grpc_port),
      grpc_listener: Application.get_env(:snakepit, :grpc_listener)
    }
  end

  defp restore_env(env) do
    stop_test_supervisor()
    Snakepit.GRPC.Listener.clear_listener_info()
    Application.stop(:snakepit)

    # Wait for processes to actually stop
    assert_eventually(
      fn ->
        Process.whereis(Snakepit.Pool) == nil
      end,
      timeout: 5_000,
      interval: 100
    )

    restore_key(:pooling_enabled, env.pooling_enabled)
    restore_key(:adapter_module, env.adapter_module)
    restore_key(:grpc_port, env.grpc_port)
    restore_key(:grpc_listener, env.grpc_listener)

    # Restart the application with original config for subsequent tests
    {:ok, _} = Application.ensure_all_started(:snakepit)

    # Wait for new pool to be ready
    if env.pooling_enabled do
      assert_eventually(
        fn ->
          Snakepit.Pool.await_ready(Snakepit.Pool, 5_000) == :ok
        end,
        timeout: 30_000,
        interval: 1_000
      )
    end
  end

  defp stop_test_supervisor do
    if sup = Process.get(:test_supervisor) do
      Supervisor.stop(sup)
      Process.delete(:test_supervisor)
    end
  end

  defp restore_key(key, nil), do: Application.delete_env(:snakepit, key)
  defp restore_key(key, value), do: Application.put_env(:snakepit, key, value)
end
