defmodule Snakepit.IntegrationTest do
  use ExUnit.Case, async: false

  alias Snakepit.WorkerProfile.Process
  alias Snakepit.WorkerProfile.Thread

  @moduletag :integration

  describe "Core v0.6.0 integration - Config + WorkerProfile + Pool" do
    test "backward compatibility: legacy config still works" do
      # THIS IS THE MOST IMPORTANT TEST
      # Validates that v0.5.x users' code still works

      # Clear any pool configs from previous tests
      Application.delete_env(:snakepit, :pools)
      Application.delete_env(:snakepit, :pool_config)

      # Set legacy config (like v0.5.x)
      Application.put_env(:snakepit, :pool_size, 2)
      Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)

      # Config system should convert to new format
      {:ok, pool_configs} = Snakepit.Config.get_pool_configs()

      # Should get default pool with process profile
      assert [pool_config] = pool_configs
      assert pool_config.name == :default
      assert pool_config.worker_profile == :process
      assert pool_config.pool_size == 2
    end
  end

  describe "WorkerProfile modules work correctly" do
    test "ProcessProfile.get_capacity returns 1" do
      # Process profile: single request at a time
      assert Process.get_capacity(:fake_pid) == 1
    end

    test "ThreadProfile.get_capacity returns threads_per_worker or defaults" do
      # Thread profile: multiple concurrent requests
      capacity = Thread.get_capacity(:fake_pid)
      assert capacity >= 1
    end

    test "ProcessProfile metadata shows single-threaded" do
      {:ok, meta} = Process.get_metadata(:fake_worker)

      assert meta.profile == :process
      assert meta.capacity == 1
      assert meta.worker_type == "single-process"
      assert meta.threading == "single-threaded"
    end

    test "ThreadProfile metadata shows multi-threaded" do
      {:ok, meta} = Thread.get_metadata(:fake_worker)

      assert meta.profile == :thread
      assert meta.worker_type == "multi-threaded"
      assert meta.threading == "thread-pool"
    end
  end
end
