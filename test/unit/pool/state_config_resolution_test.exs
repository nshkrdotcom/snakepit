defmodule Snakepit.Pool.StateConfigResolutionTest do
  use ExUnit.Case, async: false

  alias Snakepit.Pool.State

  defmodule PoolAdapter do
  end

  defmodule LegacyAdapter do
  end

  defmodule GlobalAdapter do
  end

  setup do
    previous = %{
      adapter_module: Application.get_env(:snakepit, :adapter_module),
      capacity_strategy: Application.get_env(:snakepit, :capacity_strategy),
      pool_config: Application.get_env(:snakepit, :pool_config)
    }

    on_exit(fn ->
      restore_env(:adapter_module, previous.adapter_module)
      restore_env(:capacity_strategy, previous.capacity_strategy)
      restore_env(:pool_config, previous.pool_config)
    end)

    :ok
  end

  test "multi-pool state prefers per-pool adapter and capacity strategy" do
    Application.put_env(:snakepit, :adapter_module, GlobalAdapter)
    Application.put_env(:snakepit, :capacity_strategy, :profile)

    Application.put_env(:snakepit, :pool_config, %{
      adapter_module: LegacyAdapter,
      capacity_strategy: :hybrid
    })

    pool_config = %{
      name: :multi_pool,
      pool_size: 3,
      adapter_module: PoolAdapter,
      capacity_strategy: :pool
    }

    state = State.build_pool_state([], pool_config, true)

    assert state.adapter_module == PoolAdapter
    assert state.capacity_strategy == :pool
  end

  test "legacy mode state falls back to legacy pool_config precedence" do
    Application.put_env(:snakepit, :adapter_module, GlobalAdapter)
    Application.put_env(:snakepit, :capacity_strategy, :profile)

    Application.put_env(:snakepit, :pool_config, %{
      adapter_module: LegacyAdapter,
      capacity_strategy: :hybrid
    })

    state = State.build_pool_state([], %{name: :legacy_pool, pool_size: 2}, false)

    assert state.adapter_module == LegacyAdapter
    assert state.capacity_strategy == :hybrid
  end

  test "legacy mode state ignores opts[:size] and uses normalized pool_config pool_size" do
    pool_config = %{name: :legacy_pool, pool_size: 2}

    state = State.build_pool_state([size: 99], pool_config, false)

    assert state.size == 2
  end

  defp restore_env(key, nil), do: Application.delete_env(:snakepit, key)
  defp restore_env(key, value), do: Application.put_env(:snakepit, key, value)
end
