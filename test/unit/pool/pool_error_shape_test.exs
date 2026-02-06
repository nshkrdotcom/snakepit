defmodule Snakepit.Pool.ErrorShapeTest do
  use ExUnit.Case, async: true

  alias Snakepit.Pool

  setup do
    cache = :ets.new(:pool_error_shape_cache, [:set, :public, {:read_concurrency, true}])

    on_exit(fn ->
      try do
        :ets.delete(cache)
      catch
        :error, :badarg -> :ok
      end
    end)

    state = %Pool{pools: %{}, affinity_cache: cache, default_pool: :default}
    {:ok, state: state}
  end

  test "get_stats returns pool_not_found tuple with pool name", %{state: state} do
    assert {:reply, {:error, {:pool_not_found, :missing_pool}}, ^state} =
             Pool.handle_call({:get_stats, :missing_pool}, {self(), make_ref()}, state)
  end

  test "list_workers returns pool_not_found tuple with pool name", %{state: state} do
    assert {:reply, {:error, {:pool_not_found, :missing_pool}}, ^state} =
             Pool.handle_call({:list_workers, :missing_pool}, {self(), make_ref()}, state)
  end

  test "await_ready returns pool_not_found tuple with pool name", %{state: state} do
    assert {:reply, {:error, {:pool_not_found, :missing_pool}}, ^state} =
             Pool.handle_call({:await_ready, :missing_pool}, {self(), make_ref()}, state)
  end

  test "checkout_worker returns pool_not_found tuple with pool name", %{state: state} do
    assert {:reply, {:error, {:pool_not_found, :missing_pool}}, ^state} =
             Pool.handle_call(
               {:checkout_worker, :missing_pool, "session_1"},
               {self(), make_ref()},
               state
             )
  end

  test "worker_ready returns pool_not_found tuple with inferred pool name", %{state: state} do
    assert {:reply, {:error, {:pool_not_found, :default}}, ^state} =
             Pool.handle_call({:worker_ready, "default_worker_1"}, {self(), make_ref()}, state)
  end
end
