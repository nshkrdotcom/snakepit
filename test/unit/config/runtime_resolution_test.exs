defmodule Snakepit.Config.RuntimeResolutionTest do
  use ExUnit.Case, async: false

  alias Snakepit.Adapters.GRPCPython
  alias Snakepit.Config

  defmodule OverrideAdapter do
  end

  defmodule PoolAdapter do
  end

  defmodule LegacyAdapter do
  end

  defmodule GlobalAdapter do
  end

  defmodule DefaultAdapter do
  end

  setup do
    previous = %{
      adapter_module: Application.get_env(:snakepit, :adapter_module),
      capacity_strategy: Application.get_env(:snakepit, :capacity_strategy),
      pool_config: Application.get_env(:snakepit, :pool_config),
      pools: Application.get_env(:snakepit, :pools)
    }

    on_exit(fn ->
      restore_env(:adapter_module, previous.adapter_module)
      restore_env(:capacity_strategy, previous.capacity_strategy)
      restore_env(:pool_config, previous.pool_config)
      restore_env(:pools, previous.pools)
    end)

    :ok
  end

  test "adapter_module resolves override -> pool -> legacy -> global -> default" do
    Application.put_env(:snakepit, :adapter_module, GlobalAdapter)
    Application.put_env(:snakepit, :pool_config, %{adapter_module: LegacyAdapter})

    assert Config.adapter_module(%{}, override: OverrideAdapter, default: DefaultAdapter) ==
             OverrideAdapter

    assert Config.adapter_module(%{adapter_module: PoolAdapter}, default: DefaultAdapter) ==
             PoolAdapter

    assert Config.adapter_module(%{}, default: DefaultAdapter) == LegacyAdapter

    Application.delete_env(:snakepit, :pool_config)
    assert Config.adapter_module(%{}, default: DefaultAdapter) == GlobalAdapter

    Application.delete_env(:snakepit, :adapter_module)
    assert Config.adapter_module(%{}, default: DefaultAdapter) == DefaultAdapter
  end

  test "capacity_strategy resolves pool -> legacy -> global -> default" do
    Application.put_env(:snakepit, :capacity_strategy, :profile)
    Application.put_env(:snakepit, :pool_config, %{capacity_strategy: :hybrid})

    assert Config.capacity_strategy(%{capacity_strategy: :pool}) == :pool
    assert Config.capacity_strategy(%{}) == :hybrid

    Application.delete_env(:snakepit, :pool_config)
    assert Config.capacity_strategy(%{}) == :profile

    Application.delete_env(:snakepit, :capacity_strategy)
    assert Config.capacity_strategy(%{}) == Snakepit.Defaults.default_capacity_strategy()
  end

  test "adapter_args resolves from legacy pool_config when present" do
    Application.put_env(:snakepit, :pool_config, %{adapter_args: ["--adapter", "legacy.Adapter"]})
    assert Config.adapter_args(%{}) == ["--adapter", "legacy.Adapter"]
  end

  test "multi_pool_mode?/0 reflects explicit pools configuration" do
    Application.delete_env(:snakepit, :pools)
    refute Config.multi_pool_mode?()

    Application.put_env(:snakepit, :pools, [])
    assert Config.multi_pool_mode?()
  end

  test "GRPCPython.script_args uses resolved adapter args from config helper" do
    Application.put_env(:snakepit, :pool_config, %{adapter_args: ["--adapter", "custom.Adapter"]})
    assert GRPCPython.script_args() == ["--adapter", "custom.Adapter"]
  end

  defp restore_env(key, nil), do: Application.delete_env(:snakepit, key)
  defp restore_env(key, value), do: Application.put_env(:snakepit, key, value)
end
