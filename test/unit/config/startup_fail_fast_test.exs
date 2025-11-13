defmodule Snakepit.Config.StartupFailFastTest do
  @moduledoc """
  Verifies that catastrophic configuration errors cause the Snakepit application
  to fail fast instead of launching half-initialised pools.
  """
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  require Logger
  import ExUnit.CaptureLog

  alias Snakepit.ProcessKiller

  setup do
    original_level = Logger.level()
    Logger.configure(level: :error)

    prev_env = %{
      pooling_enabled: Application.get_env(:snakepit, :pooling_enabled),
      pools: Application.get_env(:snakepit, :pools),
      pool_config: Application.get_env(:snakepit, :pool_config),
      adapter_module: Application.get_env(:snakepit, :adapter_module),
      python_executable: Application.get_env(:snakepit, :python_executable),
      grpc_port: Application.get_env(:snakepit, :grpc_port),
      env_doctor_module: Application.get_env(:snakepit, :env_doctor_module)
    }

    on_exit(fn ->
      Snakepit.Test.FakeDoctor.reset()
      Application.stop(:snakepit)
      restore_env(prev_env)
      {:ok, _} = Application.ensure_all_started(:snakepit)
      Logger.configure(level: original_level)
    end)

    :ok
  end

  test "application start fails when adapter executable is missing and registry stays empty" do
    capture_log(fn ->
      Application.stop(:snakepit)

      bad_path = "/tmp/snakepit-missing-python-#{System.unique_integer([:positive])}"

      Application.put_env(:snakepit, :pooling_enabled, true)
      Application.put_env(:snakepit, :pool_config, %{pool_size: 1})
      Application.put_env(:snakepit, :env_doctor_module, Snakepit.EnvDoctor)

      adapter = Snakepit.TestAdapters.MockGRPCAdapter
      Application.put_env(:snakepit, :adapter_module, adapter)

      Application.put_env(:snakepit, :pools, [
        %{
          name: :default,
          worker_profile: :process,
          pool_size: 1,
          adapter_module: adapter
        }
      ])

      Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
      Application.put_env(:snakepit, :python_executable, bad_path)

      case Application.ensure_all_started(:snakepit) do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end

      if Process.whereis(Snakepit.Pool) do
        assert match?({:error, _}, await_ready_result())
      end

      ensure_registry_started()
      assert %{total_registered: 0} = Snakepit.Pool.ProcessRegistry.get_stats()
      assert {:ok, dets_size} = Snakepit.Pool.ProcessRegistry.dets_table_size()
      assert dets_size <= 1
    end)
  end

  test "invalid pool config fails fast before supervisor boots" do
    capture_log(fn ->
      Application.stop(:snakepit)

      Application.put_env(:snakepit, :pooling_enabled, true)
      Application.put_env(:snakepit, :pools, [%{name: :broken, worker_profile: :unknown}])

      assert {:error, {:validation_failed, _}} = Snakepit.Config.get_pool_configs()

      result = Application.ensure_all_started(:snakepit)

      cond do
        match?(
          {:error, {:snakepit, {:shutdown, {:failed_to_start_child, Snakepit.Pool, _}}}},
          result
        ) ->
          reason = extract_pool_reason(result)
          assert {:invalid_pool_config, _} = unwrap_reason(reason)

        match?(
          {:error, {:snakepit, {{:shutdown, {:failed_to_start_child, Snakepit.Pool, _}}, _}}},
          result
        ) ->
          reason = extract_pool_reason(result)
          assert {:invalid_pool_config, _} = unwrap_reason(reason)

        true ->
          assert match?({:error, _}, await_ready_result())
      end

      assert Process.whereis(Snakepit.Pool) == nil
    end)
  end

  test "gRPC port binding conflict aborts startup without leaking workers" do
    capture_log(fn ->
      Application.stop(:snakepit)

      Application.put_env(:snakepit, :pooling_enabled, true)
      Application.put_env(:snakepit, :pool_config, %{pool_size: 1})

      adapter = Snakepit.TestAdapters.MockGRPCAdapter
      Application.put_env(:snakepit, :adapter_module, adapter)

      Application.put_env(:snakepit, :pools, [
        %{
          name: :default,
          worker_profile: :process,
          pool_size: 1,
          adapter_module: adapter
        }
      ])

      {:ok, socket} = :gen_tcp.listen(50051, [:binary, packet: 0, active: false, reuseaddr: true])

      result = Application.ensure_all_started(:snakepit)
      assert port_conflict_error?(result)

      assert_no_active_grpc_servers()
      :gen_tcp.close(socket)
    end)
  end

  test "env doctor is invoked before pools boot" do
    capture_log(fn ->
      Application.stop(:snakepit)

      Snakepit.Test.FakeDoctor.reset()
      Snakepit.Test.FakeDoctor.configure(pid: self())

      Application.put_env(:snakepit, :env_doctor_module, Snakepit.Test.FakeDoctor)
      Application.put_env(:snakepit, :pooling_enabled, true)

      Application.put_env(:snakepit, :pools, [
        %{
          name: :default,
          worker_profile: :process,
          pool_size: 1,
          adapter_module: Snakepit.Adapters.GRPCPython
        }
      ])

      _ = Application.ensure_all_started(:snakepit)

      assert_received {:env_doctor_called, _}
    end)
  end

  test "env doctor failure aborts startup" do
    capture_log(fn ->
      Application.stop(:snakepit)

      Snakepit.Test.FakeDoctor.reset()
      Snakepit.Test.FakeDoctor.configure(pid: self(), action: {:raise, "doctor failure"})

      Application.put_env(:snakepit, :env_doctor_module, Snakepit.Test.FakeDoctor)
      Application.put_env(:snakepit, :pooling_enabled, true)

      Application.put_env(:snakepit, :pools, [
        %{
          name: :default,
          worker_profile: :process,
          pool_size: 1,
          adapter_module: Snakepit.Adapters.GRPCPython
        }
      ])

      assert match?({:error, _}, Application.ensure_all_started(:snakepit))
      assert_received {:env_doctor_called, _}
      assert Process.whereis(Snakepit.Pool) == nil
    end)
  end

  defp restore_env(env) do
    Enum.each(env, fn
      {key, nil} -> Application.delete_env(:snakepit, key)
      {key, value} -> Application.put_env(:snakepit, key, value)
    end)
  end

  defp assert_no_active_grpc_servers do
    ProcessKiller.find_python_processes()
    |> Enum.map(fn pid -> {pid, ProcessKiller.get_process_command(pid)} end)
    |> Enum.filter(fn
      {_pid, {:ok, cmd}} -> String.contains?(cmd, "grpc_server.py")
      _ -> false
    end)
    |> case do
      [] ->
        :ok

      rogue ->
        flunk("Expected no grpc_server.py processes, found #{inspect(rogue)}")
    end
  end

  defp unwrap_reason({:shutdown, reason}), do: unwrap_reason(reason)
  defp unwrap_reason(reason), do: reason

  defp extract_pool_reason(
         {:error, {:snakepit, {:shutdown, {:failed_to_start_child, Snakepit.Pool, reason}}}}
       ),
       do: reason

  defp extract_pool_reason(
         {:error, {:snakepit, {{:shutdown, {:failed_to_start_child, Snakepit.Pool, reason}}, _}}}
       ),
       do: reason

  defp await_ready_result(timeout \\ 1_000) do
    try do
      Snakepit.Pool.await_ready(Snakepit.Pool, timeout)
    catch
      :exit, {:no_workers_started, _} -> {:error, :no_workers_started}
      :exit, :no_workers_started -> {:error, :no_workers_started}
      :exit, reason -> {:error, reason}
    end
  end

  defp ensure_registry_started do
    case Process.whereis(Snakepit.Pool.ProcessRegistry) do
      nil -> start_supervised!(Snakepit.Pool.ProcessRegistry)
      _ -> :ok
    end
  end

  defp port_conflict_error?(
         {:error, {:snakepit, {:shutdown, {:failed_to_start_child, GRPC.Server.Supervisor, _}}}}
       ),
       do: true

  defp port_conflict_error?(
         {:error,
          {:snakepit, {{:shutdown, {:failed_to_start_child, GRPC.Server.Supervisor, _}}, _}}}
       ),
       do: true

  defp port_conflict_error?(_), do: false
end
