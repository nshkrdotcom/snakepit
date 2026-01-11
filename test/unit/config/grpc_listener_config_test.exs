defmodule Snakepit.Config.GRPCListenerConfigTest do
  use ExUnit.Case, async: false

  alias Snakepit.Config
  alias Snakepit.Defaults

  setup do
    original_env = %{
      grpc_listener: Application.get_env(:snakepit, :grpc_listener),
      grpc_port: Application.get_env(:snakepit, :grpc_port),
      grpc_host: Application.get_env(:snakepit, :grpc_host)
    }

    on_exit(fn ->
      restore_env(:grpc_listener, original_env.grpc_listener)
      restore_env(:grpc_port, original_env.grpc_port)
      restore_env(:grpc_host, original_env.grpc_host)
    end)

    :ok
  end

  test "defaults to internal listener when no config is set" do
    Application.delete_env(:snakepit, :grpc_listener)
    Application.delete_env(:snakepit, :grpc_port)
    Application.delete_env(:snakepit, :grpc_host)

    assert {:ok, config} = Config.grpc_listener_config()
    assert config.mode == :internal
    assert config.port == 0
    assert config.host == Defaults.grpc_internal_host()
    assert config.bind_host == Defaults.grpc_internal_host()
  end

  test "external mode requires host and port" do
    Application.put_env(:snakepit, :grpc_listener, %{mode: :external, port: 50_051})

    assert {:error, {:invalid_grpc_listener_config, _reason}} =
             Config.grpc_listener_config()
  end

  test "external pool mode defaults pool size" do
    Application.put_env(:snakepit, :grpc_listener, %{
      mode: :external_pool,
      host: "localhost",
      base_port: 50_051
    })

    assert {:ok, config} = Config.grpc_listener_config()
    assert config.mode == :external_pool
    assert config.base_port == 50_051
    assert config.pool_size == Defaults.grpc_port_pool_size()
  end

  test "legacy grpc_port/grpc_host config maps to external mode" do
    Application.delete_env(:snakepit, :grpc_listener)
    Application.put_env(:snakepit, :grpc_port, 50_051)
    Application.put_env(:snakepit, :grpc_host, "localhost")

    assert {:ok, config} = Config.grpc_listener_config()
    assert config.mode == :external
    assert config.port == 50_051
    assert config.host == "localhost"
  end

  defp restore_env(key, nil), do: Application.delete_env(:snakepit, key)
  defp restore_env(key, value), do: Application.put_env(:snakepit, key, value)
end
