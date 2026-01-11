defmodule Snakepit.Integration.OrphanCleanupStressTest do
  @moduledoc """
  Exercises a full BEAM stop/start cycle to ensure orphaned Python workers are
  cleaned up and DETS state does not accumulate across runs.
  """
  use ExUnit.Case, async: false
  import Snakepit.TestHelpers

  alias Snakepit.Pool.ProcessRegistry
  alias Snakepit.ProcessKiller
  alias Snakepit.Config

  @moduletag :integration
  @moduletag timeout: 120_000
  @moduletag :python_integration

  @pool_size 8

  setup do
    prev_env = capture_env()

    stop_snakepit_and_wait()
    configure_pooling()
    instance_name = "snakepit_test_#{System.unique_integer([:positive])}"
    Application.put_env(:snakepit, :instance_name, instance_name)
    Application.put_env(:snakepit, :instance_token, "snakepit_test_#{Snakepit.RunID.generate()}")
    {:ok, _} = Application.ensure_all_started(:snakepit)
    assert :ok = Snakepit.Pool.await_ready(Snakepit.Pool, 60_000)

    on_exit(fn ->
      stop_snakepit_and_wait()
      restore_env(prev_env)
      {:ok, _} = Application.ensure_all_started(:snakepit)
    end)

    :ok
  end

  test "python workers are cleaned after crash/restart cycles" do
    saturate_pool()

    stats = ProcessRegistry.get_stats()
    assert stats.total_registered >= @pool_size
    assert stats.alive_workers >= 1

    reboot_snakepit()

    current_run_id = ProcessRegistry.get_beam_run_id()
    assert_no_orphan_python_processes(current_run_id)

    :ok = ProcessRegistry.manual_orphan_cleanup()

    assert_eventually(
      fn ->
        :ok = ProcessRegistry.manual_orphan_cleanup()
        {entries_info, registry_run_id} = ProcessRegistry.debug_show_all_entries()

        current_entries = Enum.count(entries_info, & &1.is_current_run)

        registry_run_id == current_run_id and
          match?({:ok, ^current_entries}, ProcessRegistry.dets_table_size())
      end,
      timeout: 30_000,
      interval: 250
    )

    {entries_info, registry_run_id} = ProcessRegistry.debug_show_all_entries()
    assert registry_run_id == current_run_id

    Enum.each(entries_info, fn entry ->
      comment =
        "stale entry #{entry.worker_id} must not have a live OS pid when run id differs"

      if entry.is_current_run do
        assert entry.process_alive, "current worker #{entry.worker_id} should be alive"
      else
        refute entry.process_alive, comment
      end
    end)

    current_entries = Enum.count(entries_info, & &1.is_current_run)
    assert {:ok, dets_size} = ProcessRegistry.dets_table_size()
    assert dets_size == current_entries

    # Second reboot ensures DETS does not grow
    reboot_snakepit()
    :ok = ProcessRegistry.manual_orphan_cleanup()

    second_run_id = ProcessRegistry.get_beam_run_id()
    assert_no_orphan_python_processes(second_run_id)

    assert_eventually(
      fn ->
        match?(
          {:ok, dets_size_after_second} when dets_size_after_second <= @pool_size,
          ProcessRegistry.dets_table_size()
        )
      end,
      timeout: 30_000,
      interval: 250
    )

    {:ok, dets_size_after_second} = ProcessRegistry.dets_table_size()
    assert dets_size_after_second <= @pool_size

    stats_after = ProcessRegistry.get_stats()
    assert stats_after.dead_workers == 0
  end

  defp saturate_pool do
    tasks =
      Task.async_stream(
        1..(@pool_size * 5),
        fn idx ->
          Snakepit.execute("ping", %{"index" => idx}, timeout: 10_000)
        end,
        max_concurrency: 16,
        timeout: 15_000
      )

    Enum.each(tasks, fn
      {:ok, result} ->
        assert match?({:ok, _}, result) or match?({:error, _}, result)

      {:exit, reason} ->
        flunk("load generation crashed: #{inspect(reason)}")
    end)
  end

  defp reboot_snakepit do
    stop_snakepit_and_wait()
    {:ok, _} = Application.ensure_all_started(:snakepit)

    assert_eventually(
      fn ->
        Process.whereis(Snakepit.Pool) &&
          match?({:ok, _}, ProcessRegistry.dets_table_size())
      end,
      timeout: 30_000,
      interval: 250
    )

    :ok = Snakepit.Pool.await_ready(Snakepit.Pool, 60_000)
  end

  defp stop_snakepit_and_wait do
    sup_pid = Process.whereis(Snakepit.Supervisor)
    sup_ref = if sup_pid && Process.alive?(sup_pid), do: Process.monitor(sup_pid)

    Application.stop(:snakepit)

    if sup_ref do
      receive do
        {:DOWN, ^sup_ref, :process, ^sup_pid, _reason} ->
          :ok
      after
        10_000 ->
          flunk("Timeout waiting for Snakepit supervisor to terminate")
      end
    end
  end

  defp assert_no_orphan_python_processes(current_run_id) do
    instance_name = Config.instance_name_identifier()
    instance_token = Config.instance_token_identifier()
    python_pids = ProcessKiller.find_python_processes()

    offenders =
      Enum.flat_map(
        python_pids,
        &check_for_orphan(&1, current_run_id, instance_name, instance_token)
      )

    assert offenders == [],
           "Found grpc_server processes from another run: #{inspect(offenders)}"
  end

  defp check_for_orphan(pid, current_run_id, instance_name, instance_token) do
    with {:ok, cmd} <- ProcessKiller.get_process_command(pid),
         true <- String.contains?(cmd, "grpc_server.py"),
         true <-
           ProcessKiller.command_matches_instance?(cmd, instance_name,
             allow_missing: false,
             instance_token: instance_token,
             allow_missing_token: false
           ),
         {:ok, run_id} <- Snakepit.RunID.extract_from_command(cmd),
         true <- run_id != current_run_id do
      [{pid, cmd}]
    else
      _ -> []
    end
  end

  defp configure_pooling do
    Application.put_env(:snakepit, :pooling_enabled, true)
    Application.put_env(:snakepit, :pool_config, %{pool_size: @pool_size})

    Application.put_env(:snakepit, :pools, [
      %{
        name: :default,
        worker_profile: :process,
        pool_size: @pool_size,
        adapter_module: Snakepit.Adapters.GRPCPython
      }
    ])
  end

  defp capture_env do
    %{
      pooling_enabled: Application.get_env(:snakepit, :pooling_enabled),
      pools: Application.get_env(:snakepit, :pools),
      pool_config: Application.get_env(:snakepit, :pool_config),
      adapter_module: Application.get_env(:snakepit, :adapter_module),
      instance_name: Application.get_env(:snakepit, :instance_name),
      instance_token: Application.get_env(:snakepit, :instance_token)
    }
  end

  defp restore_env(env) do
    Enum.each(env, fn
      {key, nil} -> Application.delete_env(:snakepit, key)
      {key, value} -> Application.put_env(:snakepit, key, value)
    end)
  end
end
