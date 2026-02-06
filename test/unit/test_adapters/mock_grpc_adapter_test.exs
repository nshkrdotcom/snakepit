defmodule Snakepit.TestAdapters.MockGRPCAdapterTest do
  use ExUnit.Case, async: true

  alias Snakepit.TestAdapters.MockGRPCAdapter

  test "init_grpc_connection returns explicit mock channel metadata" do
    assert {:ok, %{channel: channel, port: 12_345}} =
             MockGRPCAdapter.init_grpc_connection(12_345)

    assert is_map(channel)
    assert Map.fetch!(channel, :mock) == true
    assert Map.fetch!(channel, :adapter) == MockGRPCAdapter
    assert Map.fetch!(channel, :port) == 12_345
  end

  test "adapter exposes grpc_heartbeat for heartbeat monitor compatibility" do
    assert function_exported?(MockGRPCAdapter, :grpc_heartbeat, 2)
    assert function_exported?(MockGRPCAdapter, :grpc_heartbeat, 3)
  end

  test "slow_operation honors both atom and string delay keys" do
    {:ok, connection} = MockGRPCAdapter.init_grpc_connection(1)

    atom_elapsed_ms =
      elapsed_ms(fn ->
        assert {:ok, %{"status" => "completed"}} =
                 MockGRPCAdapter.grpc_execute(
                   connection,
                   "s1",
                   "slow_operation",
                   %{delay: 30},
                   5_000
                 )
      end)

    string_elapsed_ms =
      elapsed_ms(fn ->
        assert {:ok, %{"status" => "completed"}} =
                 MockGRPCAdapter.grpc_execute(
                   connection,
                   "s1",
                   "slow_operation",
                   %{"delay" => 30},
                   5_000
                 )
      end)

    assert atom_elapsed_ms >= 20
    assert string_elapsed_ms >= 20
  end

  defp elapsed_ms(fun) when is_function(fun, 0) do
    start = System.monotonic_time(:millisecond)
    fun.()
    System.monotonic_time(:millisecond) - start
  end
end
