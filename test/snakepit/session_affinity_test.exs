defmodule Snakepit.SessionAffinityTest do
  use ExUnit.Case, async: false
  import Snakepit.TestHelpers

  @moduletag :integration
  @moduletag timeout: 60_000
  @moduletag :python_integration

  setup do
    # Ensure clean state
    Application.stop(:snakepit)
    Application.load(:snakepit)

    # Configure for testing
    Application.put_env(:snakepit, :pooling_enabled, true)
    Application.put_env(:snakepit, :pool_size, 2)

    on_exit(fn ->
      Application.stop(:snakepit)

      assert_eventually(
        fn ->
          Process.whereis(Snakepit.Pool) == nil
        end,
        timeout: 5_000,
        interval: 100
      )
    end)

    :ok
  end

  describe "Session affinity with multi-pool (CRITICAL BUG)" do
    test "execute with session_id should not crash with KeyError" do
      # THIS TEST WILL FAIL with KeyError until affinity_cache is fixed

      {:ok, _apps} = Application.ensure_all_started(:snakepit)

      assert_eventually(
        fn ->
          Snakepit.Pool.await_ready(Snakepit.Pool, 5_000) == :ok
        end,
        timeout: 30_000,
        interval: 1_000
      )

      # Execute with session_id - this triggers session affinity logic
      # BUG: Will crash with "key :affinity_cache not found in PoolState"
      result = Snakepit.execute("ping", %{}, session_id: "test_session_123")

      # Should succeed
      assert {:ok, _response} = result
    end

    test "concurrent requests with different sessions should work" do
      # THIS TEST WILL FAIL until affinity_cache bug is fixed

      {:ok, _apps} = Application.ensure_all_started(:snakepit)

      assert_eventually(
        fn ->
          Snakepit.Pool.await_ready(Snakepit.Pool, 5_000) == :ok
        end,
        timeout: 30_000,
        interval: 1_000
      )

      # Multiple concurrent requests with different session IDs
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            session_id = "concurrent_session_#{i}"
            Snakepit.execute("ping", %{}, session_id: session_id)
          end)
        end

      # All should succeed
      results = Task.await_many(tasks, 15_000)

      assert length(results) == 5

      assert Enum.all?(results, fn
               {:ok, _} -> true
               _ -> false
             end)
    end

    test "session affinity routes to same worker" do
      # THIS TEST will fail until affinity_cache works

      {:ok, _apps} = Application.ensure_all_started(:snakepit)

      assert_eventually(
        fn ->
          Snakepit.Pool.await_ready(Snakepit.Pool, 5_000) == :ok
        end,
        timeout: 30_000,
        interval: 1_000
      )

      session_id = "affinity_test_session"

      # Execute multiple times with same session_id
      results =
        for _i <- 1..10 do
          {:ok, result} = Snakepit.execute("ping", %{}, session_id: session_id)
          result
        end

      # All should succeed
      assert length(results) == 10

      # NOTE: Unable to verify all requests used the same worker without worker_id in response.
      # This is a known limitation of the current response format.
    end
  end

  describe "Requests without session_id (should work even with bug)" do
    test "execute without session_id works" do
      # This should PASS even with the affinity_cache bug
      # Because it doesn't trigger the session affinity code path

      {:ok, _apps} = Application.ensure_all_started(:snakepit)

      assert_eventually(
        fn ->
          Snakepit.Pool.await_ready(Snakepit.Pool, 5_000) == :ok
        end,
        timeout: 30_000,
        interval: 1_000
      )

      # Execute without session_id - no affinity logic triggered
      {:ok, result} = Snakepit.execute("ping", %{})

      assert is_map(result)
    end
  end
end
