defmodule Snakepit.Internal.AsyncFallbackTest do
  use ExUnit.Case, async: true

  alias Snakepit.Internal.AsyncFallback

  test "start_monitored/1 executes function and reports result with monitor ref" do
    {:ok, pid, ref} = AsyncFallback.start_monitored(fn -> :ok end)

    assert_receive {^ref, :ok}, 500
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
  end

  test "start_monitored_fire_and_forget/1 executes function and emits monitor DOWN" do
    parent = self()

    {pid, ref} =
      AsyncFallback.start_monitored_fire_and_forget(fn ->
        send(parent, :fallback_ran)
      end)

    assert_receive :fallback_ran, 500
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
  end
end
