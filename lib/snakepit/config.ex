defmodule Snakepit.Config do
  @moduledoc """
  Configuration management for Snakepit pools.

  Handles validation and normalization of pool configurations,
  supporting both legacy single-pool and new multi-pool configurations.

  ## Backward Compatibility

  Existing v0.5.x configurations continue to work:

      # Legacy config (v0.5.x) - still works!
      config :snakepit,
        pooling_enabled: true,
        adapter_module: Snakepit.Adapters.GRPCPython,
        pool_size: 100

  ## New Multi-Pool Configuration (v0.6.0+)

      config :snakepit,
        pools: [
          %{
            name: :default,
            worker_profile: :process,
            pool_size: 100,
            adapter_module: Snakepit.Adapters.GRPCPython
          },
          %{
            name: :hpc,
            worker_profile: :thread,
            pool_size: 4,
            threads_per_worker: 16
          }
        ]

  ## Configuration Schema

  Per-pool configuration options:

  ### Required
  - `name` - Pool identifier (atom)
  - `adapter_module` - Adapter module

  ### Profile Selection
  - `worker_profile` - `:process` or `:thread` (default: `:process`)

  ### Common Options
  - `pool_size` - Number of workers
  - `adapter_args` - CLI arguments for adapter
  - `adapter_env` - Environment variables

  ### Process Profile Specific
  - `startup_batch_size` - Workers per batch (default: 8)
  - `startup_batch_delay_ms` - Delay between batches (default: 750)

  ### Thread Profile Specific
  - `threads_per_worker` - Thread pool size per worker
  - `thread_safety_checks` - Enable runtime checks

  ### Lifecycle Management
  - `worker_ttl` - Time-to-live (`:infinity` or `{value, :seconds/:minutes/:hours}`)
  - `worker_max_requests` - Max requests before recycling (`:infinity` or integer)

  """

  require Logger
  alias Snakepit.Logger, as: SLog

  @type pool_config :: map()
  @type validation_result :: {:ok, [pool_config()]} | {:error, term()}

  @default_pool_size System.schedulers_online() * 2
  @default_profile :process
  @default_batch_size 8
  @default_batch_delay 750
  @default_threads_per_worker 10

  @default_heartbeat_config %{
    enabled: false,
    ping_interval_ms: 2_000,
    timeout_ms: 10_000,
    max_missed_heartbeats: 3,
    initial_delay_ms: 0
  }

  @heartbeat_known_keys Map.keys(@default_heartbeat_config)
  @heartbeat_string_keys Enum.map(@heartbeat_known_keys, &Atom.to_string/1)

  @doc """
  Get and validate pool configurations from application environment.

  Supports both legacy single-pool and new multi-pool configurations.

  Returns `{:ok, [pool_configs]}` or `{:error, reason}`.

  ## Examples

      # With legacy config
      {:ok, [%{name: :default, worker_profile: :process, ...}]}

      # With multi-pool config
      {:ok, [%{name: :default, ...}, %{name: :hpc, ...}]}
  """
  @spec get_pool_configs() :: validation_result()
  def get_pool_configs do
    case Application.get_env(:snakepit, :pools) do
      nil ->
        # Legacy configuration - convert to new format
        convert_legacy_config()

      pools when is_list(pools) ->
        # New multi-pool configuration
        validate_pool_configs(pools)

      invalid ->
        {:error, {:invalid_pools_config, invalid}}
    end
  end

  @doc """
  Validate a single pool configuration.

  Returns `{:ok, normalized_config}` or `{:error, reason}`.
  """
  @spec validate_pool_config(map()) :: {:ok, pool_config()} | {:error, term()}
  def validate_pool_config(config) when is_map(config) do
    with :ok <- validate_required_fields(config),
         :ok <- validate_profile(config),
         :ok <- validate_pool_size(config),
         :ok <- validate_lifecycle_options(config) do
      {:ok, normalize_pool_config(config)}
    end
  end

  def validate_pool_config(invalid) do
    {:error, {:invalid_pool_config, invalid}}
  end

  @doc """
  Normalize a pool configuration by filling in defaults.

  ## Examples

      iex> Snakepit.Config.normalize_pool_config(%{name: :test})
      %{
        name: :test,
        worker_profile: :process,
        pool_size: 16,
        # ... other defaults
      }
  """
  @spec normalize_pool_config(map()) :: pool_config()
  def normalize_pool_config(config) do
    profile = Map.get(config, :worker_profile, @default_profile)

    base_config =
      config
      |> Map.put_new(:worker_profile, @default_profile)
      |> Map.put_new(:pool_size, @default_pool_size)
      |> Map.put_new(:adapter_args, [])
      |> Map.put_new(:adapter_env, [])
      |> Map.put_new(:worker_ttl, :infinity)
      |> Map.put_new(:worker_max_requests, :infinity)

    heartbeat =
      config
      |> Map.get(:heartbeat, %{})
      |> normalize_heartbeat_overrides()
      |> merge_with_heartbeat_defaults(heartbeat_defaults())

    base_config = Map.put(base_config, :heartbeat, heartbeat)

    # Add profile-specific defaults
    case profile do
      :process ->
        base_config
        |> Map.put_new(:startup_batch_size, @default_batch_size)
        |> Map.put_new(:startup_batch_delay_ms, @default_batch_delay)

      :thread ->
        base_config
        |> Map.put_new(:threads_per_worker, @default_threads_per_worker)
        |> Map.put_new(:thread_safety_checks, false)

      _ ->
        base_config
    end
  end

  @doc """
  Get configuration for a specific named pool.

  Returns `{:ok, config}` or `{:error, reason}`.

  The error can be `:pool_not_found` if the pool doesn't exist, or any error
  from `get_pool_configs/0` if there's a configuration issue.

  ## Examples

      iex> Snakepit.Config.get_pool_config(:default)
      {:ok, %{name: :default, worker_profile: :process, ...}}
  """
  @spec get_pool_config(atom()) :: {:ok, pool_config()} | {:error, term()}
  def get_pool_config(pool_name) when is_atom(pool_name) do
    case get_pool_configs() do
      {:ok, pools} ->
        case Enum.find(pools, fn pool -> Map.get(pool, :name) == pool_name end) do
          nil -> {:error, :pool_not_found}
          config -> {:ok, config}
        end

      error ->
        error
    end
  end

  @doc """
  Check if a pool configuration is using the thread profile.

  ## Examples

      iex> Snakepit.Config.thread_profile?(%{worker_profile: :thread})
      true

      iex> Snakepit.Config.thread_profile?(%{worker_profile: :process})
      false
  """
  @spec thread_profile?(pool_config()) :: boolean()
  def thread_profile?(config) when is_map(config) do
    Map.get(config, :worker_profile) == :thread
  end

  @doc """
  Get the profile module for a pool configuration.

  Returns the module that implements the WorkerProfile behaviour.

  ## Examples

      iex> Snakepit.Config.get_profile_module(%{worker_profile: :process})
      Snakepit.WorkerProfile.Process

      iex> Snakepit.Config.get_profile_module(%{worker_profile: :thread})
      Snakepit.WorkerProfile.Thread
  """
  @spec get_profile_module(pool_config()) :: module()
  def get_profile_module(config) when is_map(config) do
    case Map.get(config, :worker_profile, :process) do
      :process -> Snakepit.WorkerProfile.Process
      :thread -> Snakepit.WorkerProfile.Thread
    end
  end

  @doc """
  Returns the normalized default heartbeat configuration, merged with application env overrides.
  """
  @spec heartbeat_defaults() :: map()
  def heartbeat_defaults do
    Application.get_env(:snakepit, :heartbeat, %{})
    |> normalize_heartbeat_overrides()
    |> merge_with_heartbeat_defaults()
  end

  # Private functions

  defp convert_legacy_config do
    # Build a default pool from legacy config options
    base_pool = %{
      name: :default,
      worker_profile: :process,
      pool_size: Application.get_env(:snakepit, :pool_size, @default_pool_size),
      adapter_module: Application.get_env(:snakepit, :adapter_module),
      adapter_args: [],
      adapter_env: []
    }

    # Add pool_config if present
    legacy_pool =
      if pool_config = Application.get_env(:snakepit, :pool_config) do
        Map.merge(base_pool, %{
          startup_batch_size: Map.get(pool_config, :startup_batch_size, @default_batch_size),
          startup_batch_delay_ms:
            Map.get(pool_config, :startup_batch_delay_ms, @default_batch_delay),
          max_workers: Map.get(pool_config, :max_workers, 1000)
        })
      else
        base_pool
      end

    case validate_pool_config(legacy_pool) do
      {:ok, config} ->
        SLog.info("Converted legacy configuration to pool config for :default pool")
        {:ok, [config]}

      error ->
        error
    end
  end

  defp validate_pool_configs(pools) do
    results =
      Enum.map(pools, fn pool ->
        validate_pool_config(pool)
      end)

    errors =
      Enum.filter(results, fn
        {:error, _} -> true
        _ -> false
      end)

    if Enum.empty?(errors) do
      configs = Enum.map(results, fn {:ok, config} -> config end)
      check_duplicate_names(configs)
    else
      {:error, {:validation_failed, errors}}
    end
  end

  defp check_duplicate_names(configs) do
    names = Enum.map(configs, & &1.name)
    duplicates = names -- Enum.uniq(names)

    if Enum.empty?(duplicates) do
      {:ok, configs}
    else
      {:error, {:duplicate_pool_names, duplicates}}
    end
  end

  defp validate_required_fields(config) do
    required = [:name]

    missing =
      Enum.filter(required, fn field ->
        not Map.has_key?(config, field) or is_nil(Map.get(config, field))
      end)

    if Enum.empty?(missing) do
      :ok
    else
      {:error, {:missing_required_fields, missing}}
    end
  end

  defp validate_profile(config) do
    case Map.get(config, :worker_profile, :process) do
      profile when profile in [:process, :thread] ->
        :ok

      invalid ->
        {:error, {:invalid_profile, invalid, "must be :process or :thread"}}
    end
  end

  defp validate_pool_size(config) do
    case Map.get(config, :pool_size, @default_pool_size) do
      size when is_integer(size) and size > 0 ->
        :ok

      invalid ->
        {:error, {:invalid_pool_size, invalid, "must be positive integer"}}
    end
  end

  defp validate_lifecycle_options(config) do
    with :ok <- validate_ttl(config),
         :ok <- validate_max_requests(config) do
      :ok
    end
  end

  defp validate_ttl(config) do
    case Map.get(config, :worker_ttl, :infinity) do
      :infinity ->
        :ok

      {value, unit}
      when is_integer(value) and value > 0 and unit in [:seconds, :minutes, :hours] ->
        :ok

      invalid ->
        {:error,
         {:invalid_worker_ttl, invalid,
          "must be :infinity or {value, :seconds | :minutes | :hours}"}}
    end
  end

  defp validate_max_requests(config) do
    case Map.get(config, :worker_max_requests, :infinity) do
      :infinity ->
        :ok

      count when is_integer(count) and count > 0 ->
        :ok

      invalid ->
        {:error, {:invalid_worker_max_requests, invalid, "must be :infinity or positive integer"}}
    end
  end

  defp normalize_heartbeat_overrides(overrides) when is_map(overrides) do
    Enum.reduce(overrides, %{}, fn {key, value}, acc ->
      Map.put(acc, normalize_heartbeat_key(key), value)
    end)
  end

  defp normalize_heartbeat_overrides(_), do: %{}

  defp merge_with_heartbeat_defaults(overrides, base \\ @default_heartbeat_config) do
    defaults =
      Enum.reduce(base, %{}, fn {key, value}, acc ->
        Map.put(acc, key, value)
      end)

    Map.merge(defaults, overrides, fn _key, _default, override -> override end)
  end

  defp normalize_heartbeat_key(key) when is_atom(key) do
    if key in @heartbeat_known_keys do
      key
    else
      key
    end
  end

  defp normalize_heartbeat_key(key) when is_binary(key) do
    cond do
      key in @heartbeat_string_keys ->
        String.to_existing_atom(key)

      true ->
        key
    end
  rescue
    ArgumentError ->
      key
  end
end
