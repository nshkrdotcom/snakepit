defmodule Snakepit.Pool.AsyncTaskRefTest do
  use ExUnit.Case, async: true

  alias Snakepit.Pool

  test "late async task tracking message does not re-introduce completed ref" do
    ref = make_ref()
    cache = :ets.new(:pool_async_task_ref_test_cache, [:set, :public])

    on_exit(fn ->
      case :ets.info(cache) do
        :undefined -> :ok
        _ -> :ets.delete(cache)
      end
    end)

    state = %Pool{pools: %{}, affinity_cache: cache, default_pool: :default}

    assert {:noreply, after_completion} = Pool.handle_info({ref, :ok}, state)
    assert after_completion == state

    assert {:noreply, after_late_track} =
             Pool.handle_info({:track_async_task_ref, ref}, after_completion)

    assert after_late_track == state
  end
end
