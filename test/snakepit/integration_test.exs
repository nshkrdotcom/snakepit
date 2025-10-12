defmodule Snakepit.IntegrationTest do
  use ExUnit.Case, async: false

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
      assert Snakepit.WorkerProfile.Process.get_capacity(:fake_pid) == 1
    end

    test "ThreadProfile.get_capacity returns threads_per_worker or defaults" do
      # Thread profile: multiple concurrent requests
      capacity = Snakepit.WorkerProfile.Thread.get_capacity(:fake_pid)
      assert capacity >= 1
    end

    test "ProcessProfile metadata shows single-threaded" do
      {:ok, meta} = Snakepit.WorkerProfile.Process.get_metadata(:fake_worker)

      assert meta.profile == :process
      assert meta.capacity == 1
      assert meta.worker_type == "single-process"
      assert meta.threading == "single-threaded"
    end

    test "ThreadProfile metadata shows multi-threaded" do
      {:ok, meta} = Snakepit.WorkerProfile.Thread.get_metadata(:fake_worker)

      assert meta.profile == :thread
      assert meta.worker_type == "multi-threaded"
      assert meta.threading == "thread-pool"
    end
  end

  describe "Python version detection guides profile selection" do
    test "Python 3.13+ recommends thread profile" do
      assert Snakepit.PythonVersion.recommend_profile({3, 13, 0}) == :thread
      assert Snakepit.PythonVersion.recommend_profile({3, 14, 0}) == :thread
    end

    test "Python < 3.13 recommends process profile" do
      assert Snakepit.PythonVersion.recommend_profile({3, 12, 0}) == :process
      assert Snakepit.PythonVersion.recommend_profile({3, 11, 0}) == :process
      assert Snakepit.PythonVersion.recommend_profile({3, 8, 0}) == :process
    end

    test "free-threading detection works" do
      assert Snakepit.PythonVersion.supports_free_threading?({3, 13, 0}) == true
      assert Snakepit.PythonVersion.supports_free_threading?({3, 12, 0}) == false
    end
  end

  describe "Library compatibility matrix" do
    test "GIL-releasing libraries safe for thread profile" do
      # Libraries that release GIL: NumPy, PyTorch, etc.
      result = Snakepit.Compatibility.check("numpy", :thread)
      assert result == :ok or match?({:warning, _}, result)

      assert :ok = Snakepit.Compatibility.check("scipy", :thread)
    end

    test "GIL-holding libraries warn for thread profile" do
      # Libraries that hold GIL: Pandas, Matplotlib
      assert {:warning, msg} = Snakepit.Compatibility.check("pandas", :thread)
      assert String.contains?(msg, "not thread-safe")

      assert {:warning, msg} = Snakepit.Compatibility.check("matplotlib", :thread)
      assert String.contains?(msg, "not thread-safe")
    end

    test "all libraries safe with process profile" do
      # Process isolation makes everything safe
      assert :ok = Snakepit.Compatibility.check("numpy", :process)
      assert :ok = Snakepit.Compatibility.check("pandas", :process)
      assert :ok = Snakepit.Compatibility.check("torch", :process)
    end
  end
end
