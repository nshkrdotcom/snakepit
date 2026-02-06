defmodule Snakepit.Worker.ConfigurationTest do
  use ExUnit.Case, async: true

  alias Snakepit.Adapters.GRPCPython
  alias Snakepit.Worker.Configuration

  describe "build_spawn_config/6 script selection" do
    test "does not use threaded server for non-thread worker args in mixed pool configs" do
      prev_pools = Application.get_env(:snakepit, :pools)

      on_exit(fn ->
        restore_env(:pools, prev_pools)
      end)

      Application.put_env(:snakepit, :pools, [
        %{
          name: :thread_pool,
          adapter_args: ["--adapter", "thread.Adapter", "--max-workers", "32"]
        }
      ])

      spawn_config =
        Configuration.build_spawn_config(
          GRPCPython,
          %{adapter_args: ["--adapter", "process.Adapter"], adapter_env: []},
          %{},
          50_051,
          "127.0.0.1",
          "worker_process_1"
        )

      assert String.ends_with?(spawn_config.script_path, "grpc_server.py")
      refute String.ends_with?(spawn_config.script_path, "grpc_server_threaded.py")
    end

    test "uses threaded server when worker adapter args include --max-workers" do
      spawn_config =
        Configuration.build_spawn_config(
          GRPCPython,
          %{
            adapter_args: ["--adapter", "thread.Adapter", "--max-workers", "16"],
            adapter_env: []
          },
          %{},
          50_052,
          "127.0.0.1",
          "worker_thread_1"
        )

      assert String.ends_with?(spawn_config.script_path, "grpc_server_threaded.py")
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:snakepit, key)
  defp restore_env(key, value), do: Application.put_env(:snakepit, key, value)
end
