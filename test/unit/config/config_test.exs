defmodule Snakepit.ConfigTest do
  use ExUnit.Case, async: true

  alias Snakepit.Config

  describe "normalize_pool_config/1" do
    test "applies default values" do
      config = %{name: :test}
      normalized = Config.normalize_pool_config(config)

      assert normalized.name == :test
      assert normalized.worker_profile == :process
      assert is_integer(normalized.pool_size)
      assert normalized.worker_ttl == :infinity
      assert normalized.worker_max_requests == :infinity
    end

    test "preserves user-specified values" do
      config = %{
        name: :custom,
        worker_profile: :thread,
        pool_size: 42,
        worker_ttl: {3600, :seconds},
        worker_max_requests: 1000
      }

      normalized = Config.normalize_pool_config(config)

      assert normalized.name == :custom
      assert normalized.worker_profile == :thread
      assert normalized.pool_size == 42
      assert normalized.worker_ttl == {3600, :seconds}
      assert normalized.worker_max_requests == 1000
    end

    test "adds process profile defaults" do
      config = %{name: :test, worker_profile: :process}
      normalized = Config.normalize_pool_config(config)

      assert Map.has_key?(normalized, :startup_batch_size)
      assert Map.has_key?(normalized, :startup_batch_delay_ms)
    end

    test "adds thread profile defaults" do
      config = %{name: :test, worker_profile: :thread}
      normalized = Config.normalize_pool_config(config)

      assert Map.has_key?(normalized, :threads_per_worker)
      assert Map.has_key?(normalized, :thread_safety_checks)
      assert normalized.threads_per_worker > 0
      assert is_boolean(normalized.thread_safety_checks)
    end

    test "defaults capacity_strategy to :pool" do
      Application.delete_env(:snakepit, :capacity_strategy)

      normalized = Config.normalize_pool_config(%{name: :cap_default})
      assert normalized.capacity_strategy == :pool
    end

    test "prefers pool-specific capacity_strategy over global config" do
      Application.put_env(:snakepit, :capacity_strategy, :hybrid)

      on_exit(fn ->
        Application.delete_env(:snakepit, :capacity_strategy)
      end)

      normalized =
        Config.normalize_pool_config(%{
          name: :cap_override,
          capacity_strategy: :profile
        })

      assert normalized.capacity_strategy == :profile
    end

    test "injects heartbeat defaults into normalized config" do
      normalized = Config.normalize_pool_config(%{name: :hb_test})
      assert normalized.heartbeat.enabled == true
      assert normalized.heartbeat.ping_interval_ms == 2_000
      assert normalized.heartbeat.max_missed_heartbeats == 3
    end

    test "merges global heartbeat overrides from application env" do
      Application.put_env(:snakepit, :heartbeat, %{enabled: true, ping_interval_ms: 500})

      on_exit(fn ->
        Application.delete_env(:snakepit, :heartbeat)
      end)

      normalized = Config.normalize_pool_config(%{name: :hb_env_test})
      assert normalized.heartbeat.enabled == true
      assert normalized.heartbeat.ping_interval_ms == 500
      assert normalized.heartbeat.timeout_ms == 10_000
    end

    test "applies pool-specific heartbeat overrides" do
      normalized =
        Config.normalize_pool_config(%{
          name: :hb_pool,
          heartbeat: %{"enabled" => true, "max_missed_heartbeats" => 5}
        })

      assert normalized.heartbeat.enabled == true
      assert normalized.heartbeat.max_missed_heartbeats == 5
      assert normalized.heartbeat.ping_interval_ms == 2_000
    end
  end

  describe "validate_pool_config/1" do
    test "validates valid configuration" do
      config = %{
        name: :test,
        worker_profile: :process,
        pool_size: 10
      }

      assert {:ok, normalized} = Config.validate_pool_config(config)
      assert is_map(normalized)
    end

    test "rejects missing required fields" do
      config = %{worker_profile: :process}

      assert {:error, {:missing_required_fields, fields}} = Config.validate_pool_config(config)
      assert :name in fields
    end

    test "rejects invalid profile" do
      config = %{name: :test, worker_profile: :invalid}

      assert {:error, {:invalid_profile, :invalid, _}} = Config.validate_pool_config(config)
    end

    test "rejects invalid pool_size" do
      config = %{name: :test, pool_size: -1}

      assert {:error, {:invalid_pool_size, -1, _}} = Config.validate_pool_config(config)
    end

    test "rejects invalid worker_ttl" do
      config = %{name: :test, worker_ttl: "invalid"}

      assert {:error, {:invalid_worker_ttl, "invalid", _}} = Config.validate_pool_config(config)
    end

    test "accepts valid TTL formats" do
      valid_ttls = [:infinity, {3600, :seconds}, {60, :minutes}, {2, :hours}]

      for ttl <- valid_ttls do
        config = %{name: :test, worker_ttl: ttl}
        assert {:ok, _} = Config.validate_pool_config(config)
      end
    end

    test "rejects invalid worker_max_requests" do
      config = %{name: :test, worker_max_requests: -100}

      assert {:error, {:invalid_worker_max_requests, -100, _}} =
               Config.validate_pool_config(config)
    end

    test "rejects invalid capacity_strategy" do
      config = %{name: :test, capacity_strategy: :unknown}

      assert {:error, {:invalid_capacity_strategy, :unknown}} =
               Config.validate_pool_config(config)
    end
  end

  describe "thread_profile?/1" do
    test "returns true for thread profile" do
      assert Config.thread_profile?(%{worker_profile: :thread}) == true
    end

    test "returns false for process profile" do
      assert Config.thread_profile?(%{worker_profile: :process}) == false
    end

    test "returns false when profile not specified" do
      assert Config.thread_profile?(%{}) == false
    end
  end

  describe "get_profile_module/1" do
    test "returns correct module for process profile" do
      assert Config.get_profile_module(%{worker_profile: :process}) ==
               Snakepit.WorkerProfile.Process
    end

    test "returns correct module for thread profile" do
      assert Config.get_profile_module(%{worker_profile: :thread}) ==
               Snakepit.WorkerProfile.Thread
    end

    test "defaults to process profile" do
      assert Config.get_profile_module(%{}) == Snakepit.WorkerProfile.Process
    end
  end

  describe "heartbeat_defaults/0" do
    test "returns base defaults when no overrides configured" do
      Application.delete_env(:snakepit, :heartbeat)

      defaults = Config.heartbeat_defaults()
      assert defaults.enabled == true
      assert defaults.ping_interval_ms == 2_000
      assert defaults.timeout_ms == 10_000
    end

    test "merges application heartbeat overrides" do
      Application.put_env(:snakepit, :heartbeat, %{timeout_ms: 5_000})

      on_exit(fn ->
        Application.delete_env(:snakepit, :heartbeat)
      end)

      defaults = Config.heartbeat_defaults()
      assert defaults.timeout_ms == 5_000
      assert defaults.max_missed_heartbeats == 3
    end
  end

  describe "get_pool_configs/0" do
    test "legacy pool_config preserves adapter_env/adapter_args overrides" do
      prev_pools = Application.get_env(:snakepit, :pools)
      prev_pool_config = Application.get_env(:snakepit, :pool_config)
      prev_pool_size = Application.get_env(:snakepit, :pool_size)

      on_exit(fn ->
        restore_env(:pools, prev_pools)
        restore_env(:pool_config, prev_pool_config)
        restore_env(:pool_size, prev_pool_size)
      end)

      Application.delete_env(:snakepit, :pools)
      Application.put_env(:snakepit, :pool_size, 5)

      Application.put_env(:snakepit, :pool_config, %{
        pool_size: 1,
        adapter_env: %{"FOO" => "bar"},
        adapter_args: ["--adapter", "custom.Adapter"]
      })

      assert {:ok, [pool_config]} = Config.get_pool_configs()
      assert pool_config.pool_size == 1
      assert pool_config.adapter_env == %{"FOO" => "bar"}
      assert pool_config.adapter_args == ["--adapter", "custom.Adapter"]
    end

    test "fails fast on invalid worker profile" do
      Application.put_env(:snakepit, :pools, [
        %{name: :broken, worker_profile: :unknown}
      ])

      on_exit(fn -> Application.delete_env(:snakepit, :pools) end)

      assert {:error, {:validation_failed, errors}} = Config.get_pool_configs()

      assert Enum.any?(errors, fn
               {:error, {:invalid_profile, :unknown, _}} -> true
               _ -> false
             end)
    end
  end

  defp restore_env(key, value) do
    if is_nil(value) do
      Application.delete_env(:snakepit, key)
    else
      Application.put_env(:snakepit, key, value)
    end
  end
end
