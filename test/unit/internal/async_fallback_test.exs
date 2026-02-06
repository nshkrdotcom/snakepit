defmodule Snakepit.Internal.AsyncFallbackTest do
  use ExUnit.Case, async: false

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

  test "start_nolink_with_fallback/3 returns monitored fallback when supervisor is unavailable" do
    {:ok, pid, ref} =
      AsyncFallback.start_nolink_with_fallback(:missing_supervisor, fn ->
        :fallback_ok
      end)

    assert_receive {^ref, :fallback_ok}, 500
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
  end

  test "start_nolink_with_fallback/3 supports fire-and-forget fallback mode" do
    parent = self()

    {:ok, pid, ref} =
      AsyncFallback.start_nolink_with_fallback(
        :missing_supervisor,
        fn -> send(parent, :fire_and_forget_fallback) end,
        fallback_mode: :fire_and_forget
      )

    assert_receive :fire_and_forget_fallback, 500
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
  end

  test "start_child_with_fallback/3 runs fallback when supervisor is unavailable" do
    parent = self()

    assert :ok =
             AsyncFallback.start_child_with_fallback(:missing_supervisor, fn ->
               send(parent, :child_fallback_ran)
             end)

    assert_receive :child_fallback_ran, 500
  end
end
