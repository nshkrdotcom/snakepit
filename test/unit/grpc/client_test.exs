defmodule Snakepit.GRPC.ClientTest do
  use ExUnit.Case, async: true

  alias Snakepit.GRPC.Client

  test "explicit mock channel still uses mock ping behavior" do
    assert {:ok, %{message: "Pong: hello"}} = Client.ping(%{mock: true}, "hello")
  end

  test "explicit mock channel still supports custom ping hook" do
    assert {:ok, %{message: "custom pong"}} =
             Client.ping(
               %{mock: true, ping_fun: fn _message -> {:ok, %{message: "custom pong"}} end},
               "hello"
             )
  end

  test "non-map channels are no longer treated as implicit mocks" do
    assert_raise FunctionClauseError, fn ->
      Client.ping(:invalid_channel, "hello")
    end
  end

  test "mock execute_tool keeps test hook behavior" do
    test_pid = self()

    assert {:ok, %{success: true}} =
             Client.execute_tool(
               %{mock: true, test_pid: test_pid},
               "session_1",
               "tool_name",
               %{"value" => 1},
               timeout: 1_000
             )

    assert_receive {:grpc_client_execute_tool, "session_1", "tool_name", %{"value" => 1},
                    [timeout: 1_000]},
                   200
  end
end
