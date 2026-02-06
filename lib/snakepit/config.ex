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

  ## gRPC Listener Configuration

  Snakepit exposes a gRPC server for Python workers. Configure it with
  `:grpc_listener` (preferred) or legacy `:grpc_port` / `:grpc_host`.

      config :snakepit,
        grpc_listener: [mode: :internal]

      config :snakepit,
        grpc_listener: [mode: :external, host: "localhost", port: 50_051]

      config :snakepit,
        grpc_listener: [mode: :external_pool, host: "localhost", base_port: 50_051, pool_size: 8]

  Listener tuning knobs (all optional):
  - `:grpc_listener_ready_timeout_ms`
  - `:grpc_listener_port_check_interval_ms`
  - `:grpc_listener_reuse_attempts`
  - `:grpc_listener_reuse_wait_timeout_ms`
  - `:grpc_listener_reuse_retry_delay_ms`

  ## Instance Isolation

  Snakepit can scope runtime resources to avoid cross-instance collisions.
  Use `:instance_name` (or `SNAKEPIT_INSTANCE_NAME`) for a human-readable name,
  and `:instance_token` (or `SNAKEPIT_INSTANCE_TOKEN`) for strong isolation
  across concurrent runs. Runtime state is persisted under `:data_dir`.

      config :snakepit,
        instance_name: "my_app",
        instance_token: "run_a",
        data_dir: "/var/lib/snakepit"

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
  - `capacity_strategy` - `:pool`, `:profile`, or `:hybrid` (default: `:pool`)
  - `affinity` - `:hint`, `:strict_queue`, or `:strict_fail_fast` (default: `:hint`)

  ### Process Profile Specific
  - `startup_batch_size` - Workers per batch (default: 8)
  - `startup_batch_delay_ms` - Delay between batches (default: 750)

  ### Thread Profile Specific
  - `threads_per_worker` - Thread pool size per worker
  - `thread_safety_checks` - Enable runtime checks

  ### Lifecycle Management
  - `worker_ttl` - Time-to-live (`:infinity` or `{value, :seconds/:minutes/:hours}`)
  - `worker_max_requests` - Max requests before recycling (`:infinity` or integer)

  Heartbeat options are mirrored in `snakepit_bridge.heartbeat.HeartbeatConfig`,
  so any new keys added here must be added to the Python struct and documented
  in the heartbeat guides to keep both sides in sync.

  ## Normalized Shape

  `Snakepit.Config.normalize_pool_config/1` converts user input into a canonical
  map that downstream components rely on. The resulting structure (documented
  under `t:normalized_pool_config/0`) always includes heartbeat defaults,
  adapter metadata, and profile-specific knobs so pool, worker supervisor, and
  diagnostics modules never have to pattern-match on partial user input.

  """

  require Logger
  alias Snakepit.Defaults
  alias Snakepit.Logger, as: SLog

  @typedoc """
  Normalized pool configuration returned by `normalize_pool_config/1`.

  ```
  %{
    name: atom(),
    worker_profile: :process | :thread,
    pool_size: pos_integer(),
    adapter_module: module(),
    adapter_args: list(),
    adapter_env: list(),
    capacity_strategy: :pool | :profile | :hybrid,
    affinity: :hint | :strict_queue | :strict_fail_fast,
    pool_identifier: atom() | nil,
    worker_ttl: :infinity | {integer(), :seconds | :minutes | :hours},
    worker_max_requests: :infinity | pos_integer(),
    heartbeat: map(),
    # Profile-specific fields:
    startup_batch_size: pos_integer(),
    startup_batch_delay_ms: non_neg_integer(),
    threads_per_worker: pos_integer(),
    thread_safety_checks: boolean()
  }
  ```
  """
  @type pool_config :: map()
  @type normalized_pool_config :: map()
  @type validation_result :: {:ok, [pool_config()]} | {:error, term()}
  @type grpc_listener_mode :: :internal | :external | :external_pool

  @type grpc_listener_config :: %{
          mode: grpc_listener_mode(),
          host: String.t(),
          bind_host: String.t(),
          port: non_neg_integer() | nil,
          base_port: pos_integer() | nil,
          pool_size: pos_integer() | nil
        }

  # Base heartbeat config - actual runtime defaults are in Snakepit.Defaults
  @base_heartbeat_config_template %{
    enabled: true,
    dependent: true
  }

  @heartbeat_known_keys [
    :enabled,
    :ping_interval_ms,
    :timeout_ms,
    :max_missed_heartbeats,
    :initial_delay_ms,
    :dependent
  ]
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
         :ok <- validate_capacity_strategy(config),
         :ok <- validate_pool_size(config),
         :ok <- validate_affinity(config),
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
    profile = Map.get(config, :worker_profile, Defaults.default_worker_profile())

    capacity_strategy =
      Map.get(config, :capacity_strategy) ||
        Application.get_env(:snakepit, :capacity_strategy, Defaults.default_capacity_strategy())

    base_config =
      config
      |> Map.put_new(:worker_profile, Defaults.default_worker_profile())
      |> Map.put_new(:pool_size, Defaults.default_pool_size())
      |> Map.put_new(:adapter_args, [])
      |> Map.put_new(:adapter_env, [])
      |> Map.put_new(:worker_ttl, :infinity)
      |> Map.put_new(:worker_max_requests, :infinity)
      |> Map.put(:capacity_strategy, capacity_strategy)
      |> Map.put(
        :affinity,
        normalize_affinity(Map.get(config, :affinity, Defaults.default_affinity_mode()))
      )

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
        |> Map.put_new(:startup_batch_size, Defaults.pool_startup_batch_size())
        |> Map.put_new(:startup_batch_delay_ms, Defaults.pool_startup_batch_delay_ms())

      :thread ->
        base_config
        |> Map.put_new(:threads_per_worker, Defaults.config_default_threads_per_worker())
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
    with {:ok, pools} <- get_pool_configs() do
      find_pool_by_name(pools, pool_name)
    end
  end

  defp find_pool_by_name(pools, pool_name) do
    case Enum.find(pools, fn pool -> Map.get(pool, :name) == pool_name end) do
      nil -> {:error, :pool_not_found}
      config -> {:ok, config}
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

  This shape is shared with `snakepit_bridge.heartbeat.HeartbeatConfig`. When adding new keys,
  update both modules to keep the cross-language schema aligned.
  """
  @spec heartbeat_defaults() :: map()
  def heartbeat_defaults do
    Application.get_env(:snakepit, :heartbeat, %{})
    |> normalize_heartbeat_overrides()
    |> merge_with_heartbeat_defaults()
  end

  # Private functions

  defp convert_legacy_config do
    legacy_pool_config = Application.get_env(:snakepit, :pool_config, %{})

    affinity =
      Map.get(legacy_pool_config, :affinity) ||
        Application.get_env(:snakepit, :affinity, Defaults.default_affinity_mode())

    # Build a default pool from legacy config options
    base_pool = %{
      name: :default,
      worker_profile: :process,
      pool_size: Application.get_env(:snakepit, :pool_size, Defaults.default_pool_size()),
      adapter_module: Application.get_env(:snakepit, :adapter_module),
      adapter_args: [],
      adapter_env: [],
      capacity_strategy:
        Application.get_env(:snakepit, :capacity_strategy, Defaults.default_capacity_strategy()),
      affinity: affinity
    }

    # Add pool_config if present
    legacy_pool =
      case legacy_pool_config do
        %{} = pool_config when map_size(pool_config) > 0 ->
          base_pool
          |> Map.merge(pool_config)
          |> Map.put(
            :startup_batch_size,
            Map.get(pool_config, :startup_batch_size, Defaults.pool_startup_batch_size())
          )
          |> Map.put(
            :startup_batch_delay_ms,
            Map.get(pool_config, :startup_batch_delay_ms, Defaults.pool_startup_batch_delay_ms())
          )
          |> Map.put(
            :max_workers,
            Map.get(pool_config, :max_workers, Defaults.pool_max_workers())
          )

        _ ->
          base_pool
      end

    case validate_pool_config(legacy_pool) do
      {:ok, config} ->
        SLog.info(:startup, "Converted legacy configuration to pool config", pool_name: :default)
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
    case Map.get(config, :worker_profile, Defaults.default_worker_profile()) do
      profile when profile in [:process, :thread] ->
        :ok

      invalid ->
        {:error, {:invalid_profile, invalid, "must be :process or :thread"}}
    end
  end

  defp validate_capacity_strategy(config) do
    case Map.get(config, :capacity_strategy) do
      nil ->
        :ok

      strategy when strategy in [:pool, :profile, :hybrid] ->
        :ok

      invalid ->
        {:error, {:invalid_capacity_strategy, invalid}}
    end
  end

  defp validate_pool_size(config) do
    case Map.get(config, :pool_size, Defaults.default_pool_size()) do
      size when is_integer(size) and size > 0 ->
        :ok

      invalid ->
        {:error, {:invalid_pool_size, invalid, "must be positive integer"}}
    end
  end

  defp validate_affinity(config) do
    case Map.get(config, :affinity) do
      nil ->
        :ok

      mode when mode in [:hint, :strict_queue, :strict_fail_fast] ->
        :ok

      mode when is_binary(mode) ->
        case String.downcase(mode) do
          "hint" -> :ok
          "strict_queue" -> :ok
          "strict_fail_fast" -> :ok
          _ -> {:error, {:invalid_affinity, mode}}
        end

      invalid ->
        {:error, {:invalid_affinity, invalid}}
    end
  end

  defp validate_lifecycle_options(config) do
    with :ok <- validate_ttl(config) do
      validate_max_requests(config)
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

  defp default_heartbeat_config do
    Map.merge(@base_heartbeat_config_template, %{
      ping_interval_ms: Defaults.heartbeat_ping_interval_ms(),
      timeout_ms: Defaults.heartbeat_timeout_ms(),
      max_missed_heartbeats: Defaults.heartbeat_max_missed(),
      initial_delay_ms: Defaults.heartbeat_initial_delay_ms()
    })
  end

  defp merge_with_heartbeat_defaults(overrides, base \\ nil) do
    base = base || default_heartbeat_config()

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
    if key in @heartbeat_string_keys do
      String.to_existing_atom(key)
    else
      key
    end
  rescue
    ArgumentError ->
      key
  end

  @doc """
  Load and validate the gRPC listener configuration.

  Returns `{:ok, config}` or `{:error, reason}`.
  """
  @spec grpc_listener_config() :: {:ok, grpc_listener_config()} | {:error, term()}
  def grpc_listener_config do
    case Application.get_env(:snakepit, :grpc_listener) do
      nil ->
        legacy_grpc_listener_config()

      config when is_map(config) or is_list(config) ->
        normalize_grpc_listener_config(config)

      invalid ->
        {:error, {:invalid_grpc_listener_config, invalid}}
    end
  end

  @doc """
  Load the gRPC listener configuration or raise on error.
  """
  @spec grpc_listener_config!() :: grpc_listener_config()
  def grpc_listener_config! do
    case grpc_listener_config() do
      {:ok, config} -> config
      {:error, reason} -> raise ArgumentError, format_grpc_listener_error(reason)
    end
  end

  @doc """
  Timeout for waiting on the gRPC listener to publish its assigned port.
  """
  @spec grpc_listener_ready_timeout_ms() :: pos_integer()
  def grpc_listener_ready_timeout_ms do
    normalize_positive_integer(
      Application.get_env(:snakepit, :grpc_listener_ready_timeout_ms),
      Defaults.grpc_listener_ready_timeout_ms()
    )
  end

  @doc """
  Interval (ms) between port readiness checks when reusing an existing gRPC listener.
  """
  @spec grpc_listener_port_check_interval_ms() :: pos_integer()
  def grpc_listener_port_check_interval_ms do
    normalize_positive_integer(
      Application.get_env(:snakepit, :grpc_listener_port_check_interval_ms),
      Defaults.grpc_listener_port_check_interval_ms()
    )
  end

  @doc """
  Number of attempts to reuse or rebind a gRPC listener before failing.
  """
  @spec grpc_listener_reuse_attempts() :: pos_integer()
  def grpc_listener_reuse_attempts do
    normalize_positive_integer(
      Application.get_env(:snakepit, :grpc_listener_reuse_attempts),
      Defaults.grpc_listener_reuse_attempts()
    )
  end

  @doc """
  Max wait (ms) for an already-started gRPC listener to publish its port before retrying.
  """
  @spec grpc_listener_reuse_wait_timeout_ms() :: pos_integer()
  def grpc_listener_reuse_wait_timeout_ms do
    normalize_positive_integer(
      Application.get_env(:snakepit, :grpc_listener_reuse_wait_timeout_ms),
      Defaults.grpc_listener_reuse_wait_timeout_ms()
    )
  end

  @doc """
  Delay (ms) between gRPC listener reuse retries.
  """
  @spec grpc_listener_reuse_retry_delay_ms() :: pos_integer()
  def grpc_listener_reuse_retry_delay_ms do
    normalize_positive_integer(
      Application.get_env(:snakepit, :grpc_listener_reuse_retry_delay_ms),
      Defaults.grpc_listener_reuse_retry_delay_ms()
    )
  end

  @doc """
  Interval (ms) for batching DETS flushes in `Snakepit.Pool.ProcessRegistry`.
  """
  @spec process_registry_dets_flush_interval_ms() :: pos_integer()
  def process_registry_dets_flush_interval_ms do
    normalize_positive_integer(
      Application.get_env(:snakepit, :process_registry_dets_flush_interval_ms),
      Defaults.process_registry_dets_flush_interval_ms()
    )
  end

  @doc """
  Timeout for opening telemetry streams to Python workers.
  """
  @spec grpc_stream_open_timeout_ms() :: pos_integer()
  def grpc_stream_open_timeout_ms do
    normalize_positive_integer(
      Application.get_env(:snakepit, :grpc_stream_open_timeout_ms),
      Defaults.grpc_stream_open_timeout_ms()
    )
  end

  @doc """
  Timeout for sending telemetry control messages to Python workers.
  """
  @spec grpc_stream_control_timeout_ms() :: pos_integer()
  def grpc_stream_control_timeout_ms do
    normalize_positive_integer(
      Application.get_env(:snakepit, :grpc_stream_control_timeout_ms),
      Defaults.grpc_stream_control_timeout_ms()
    )
  end

  @doc """
  Maximum concurrent worker checks during lifecycle scan.
  """
  @spec lifecycle_check_max_concurrency() :: pos_integer()
  def lifecycle_check_max_concurrency do
    normalize_positive_integer(
      Application.get_env(:snakepit, :lifecycle_check_max_concurrency),
      Defaults.lifecycle_check_max_concurrency()
    )
  end

  @doc """
  Timeout (ms) per worker action during lifecycle checks.
  """
  @spec lifecycle_worker_action_timeout_ms() :: pos_integer()
  def lifecycle_worker_action_timeout_ms do
    normalize_positive_integer(
      Application.get_env(:snakepit, :lifecycle_worker_action_timeout_ms),
      Defaults.lifecycle_worker_action_timeout_ms()
    )
  end

  @doc """
  Resolve max workers for a pool, preserving legacy `:pool_config` fallback.
  """
  @spec pool_max_workers(map()) :: pos_integer()
  def pool_max_workers(pool_config \\ %{}) when is_map(pool_config) do
    legacy_pool_config = Application.get_env(:snakepit, :pool_config, %{})

    pool_config
    |> Map.get(
      :max_workers,
      Map.get(legacy_pool_config, :max_workers, Defaults.pool_max_workers())
    )
    |> normalize_positive_integer(Defaults.pool_max_workers())
  end

  @doc """
  Resolve startup batch size for process-profile worker initialization.
  """
  @spec pool_startup_batch_size(map()) :: pos_integer()
  def pool_startup_batch_size(pool_config \\ %{}) when is_map(pool_config) do
    legacy_pool_config = Application.get_env(:snakepit, :pool_config, %{})

    pool_config
    |> Map.get(
      :startup_batch_size,
      Map.get(legacy_pool_config, :startup_batch_size, Defaults.pool_startup_batch_size())
    )
    |> normalize_positive_integer(Defaults.pool_startup_batch_size())
  end

  @doc """
  Resolve startup batch delay (ms) for process-profile worker initialization.
  """
  @spec pool_startup_batch_delay_ms(map()) :: non_neg_integer()
  def pool_startup_batch_delay_ms(pool_config \\ %{}) when is_map(pool_config) do
    legacy_pool_config = Application.get_env(:snakepit, :pool_config, %{})

    pool_config
    |> Map.get(
      :startup_batch_delay_ms,
      Map.get(legacy_pool_config, :startup_batch_delay_ms, Defaults.pool_startup_batch_delay_ms())
    )
    |> normalize_non_negative_integer(Defaults.pool_startup_batch_delay_ms())
  end

  @doc """
  Worker restart cleanup polling interval in milliseconds.
  """
  @spec worker_supervisor_cleanup_retry_interval_ms() :: pos_integer()
  def worker_supervisor_cleanup_retry_interval_ms do
    normalize_positive_integer(
      Application.get_env(:snakepit, :cleanup_retry_interval_ms),
      Defaults.worker_supervisor_cleanup_retry_interval_ms()
    )
  end

  @doc """
  Worker restart cleanup maximum retry attempts.
  """
  @spec worker_supervisor_cleanup_max_retries() :: pos_integer()
  def worker_supervisor_cleanup_max_retries do
    normalize_positive_integer(
      Application.get_env(:snakepit, :cleanup_max_retries),
      Defaults.worker_supervisor_cleanup_max_retries()
    )
  end

  @doc """
  Normalized rogue cleanup configuration for process registry startup cleanup.
  """
  @spec rogue_cleanup_config() :: map()
  def rogue_cleanup_config do
    Application.get_env(:snakepit, :rogue_cleanup, Defaults.rogue_cleanup_defaults())
    |> normalize_rogue_cleanup_config()
  end

  @doc """
  Resolve the instance name used for runtime isolation.
  """
  @spec instance_name() :: String.t() | nil
  def instance_name do
    value =
      Application.get_env(:snakepit, :instance_name) ||
        System.get_env("SNAKEPIT_INSTANCE_NAME")

    normalize_instance_name_config(value)
  end

  @doc """
  Resolve the instance token used for runtime isolation.
  """
  @spec instance_token() :: String.t() | nil
  def instance_token do
    value =
      Application.get_env(:snakepit, :instance_token) ||
        System.get_env("SNAKEPIT_INSTANCE_TOKEN") ||
        Defaults.instance_token()

    normalize_instance_token_config(value)
  end

  @doc false
  @spec instance_name_configured?() :: boolean()
  def instance_name_configured? do
    app_value = Application.get_env(:snakepit, :instance_name)
    env_value = System.get_env("SNAKEPIT_INSTANCE_NAME")

    not is_nil(normalize_instance_name_config(app_value)) or
      not is_nil(normalize_instance_name_config(env_value))
  end

  @doc false
  @spec instance_token_configured?() :: boolean()
  def instance_token_configured? do
    app_value = Application.get_env(:snakepit, :instance_token)
    env_value = System.get_env("SNAKEPIT_INSTANCE_TOKEN")

    not is_nil(normalize_instance_token_config(app_value)) or
      not is_nil(normalize_instance_token_config(env_value))
  end

  @doc """
  Resolve a CLI-safe instance name identifier for process scoping.
  """
  @spec instance_name_identifier() :: String.t() | nil
  def instance_name_identifier do
    instance_name()
    |> normalize_instance_name_identifier()
    |> case do
      nil -> default_instance_name_identifier()
      normalized -> normalized
    end
  end

  @doc """
  Resolve a CLI-safe instance token identifier for process scoping.
  """
  @spec instance_token_identifier() :: String.t() | nil
  def instance_token_identifier do
    instance_token()
    |> normalize_instance_token_identifier()
  end

  @doc """
  Resolve the data directory used for runtime persistence.
  """
  @spec data_dir() :: String.t()
  def data_dir do
    value = Application.get_env(:snakepit, :data_dir) || System.get_env("SNAKEPIT_DATA_DIR")

    if is_binary(value) and value != "" do
      value
    else
      default_data_dir()
    end
  end

  defp normalize_instance_name_config(value) when is_binary(value) do
    trimmed = String.trim(value)

    case String.downcase(trimmed) do
      "" -> nil
      "nil" -> nil
      "null" -> nil
      "none" -> nil
      _ -> trimmed
    end
  end

  defp normalize_instance_name_config(value) when is_atom(value) do
    if value in [nil, nil] do
      nil
    else
      Atom.to_string(value)
    end
  end

  defp normalize_instance_name_config(_), do: nil

  defp normalize_instance_token_config(value) when is_binary(value) do
    trimmed = String.trim(value)

    case String.downcase(trimmed) do
      "" -> nil
      "nil" -> nil
      "null" -> nil
      "none" -> nil
      _ -> trimmed
    end
  end

  defp normalize_instance_token_config(value) when is_atom(value) do
    if value in [nil, nil] do
      nil
    else
      Atom.to_string(value)
    end
  end

  defp normalize_instance_token_config(_), do: nil

  defp normalize_instance_name_identifier(nil), do: nil

  defp normalize_instance_name_identifier(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_instance_token_identifier(nil), do: nil

  defp normalize_instance_token_identifier(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp default_instance_name_identifier do
    env = System.get_env("MIX_ENV") || mix_env()

    cwd =
      case File.cwd() do
        {:ok, path} -> Path.basename(path)
        _ -> nil
      end

    node_name = node() |> to_string()

    [env, cwd, node_name]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("_")
    |> normalize_instance_name_identifier()
    |> case do
      nil -> "default"
      normalized -> normalized
    end
  end

  defp mix_env do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) do
      try do
        Mix.env() |> to_string()
      rescue
        _ -> nil
      end
    end
  end

  defp legacy_grpc_listener_config do
    case Application.fetch_env(:snakepit, :grpc_port) do
      {:ok, port} when port in [0, "0"] ->
        {:ok, default_internal_listener()}

      {:ok, port} ->
        host =
          Application.get_env(:snakepit, :grpc_host, Defaults.grpc_internal_host())

        normalize_grpc_listener_config(%{mode: :external, host: host, port: port})

      :error ->
        {:ok, default_internal_listener()}
    end
  end

  defp default_internal_listener do
    host = Defaults.grpc_internal_host()

    %{
      mode: :internal,
      host: host,
      bind_host: host,
      port: 0,
      base_port: nil,
      pool_size: nil
    }
  end

  defp normalize_grpc_listener_config(config) when is_list(config) do
    config
    |> Enum.into(%{}, fn
      {key, value} when is_atom(key) -> {key, value}
      {key, value} when is_binary(key) -> {key, value}
      _ -> {:invalid, :ignored}
    end)
    |> Map.drop([:invalid])
    |> normalize_grpc_listener_config()
  end

  defp normalize_grpc_listener_config(config) when is_map(config) do
    mode = normalize_grpc_mode(fetch_value(config, :mode))

    with {:ok, mode} <- validate_grpc_mode(mode) do
      case mode do
        :internal ->
          {:ok, normalize_internal_listener(config)}

        :external ->
          normalize_external_listener(config)

        :external_pool ->
          normalize_external_pool_listener(config)
      end
    end
  end

  defp normalize_internal_listener(config) do
    host = fetch_value(config, :host) || Defaults.grpc_internal_host()
    bind_host = fetch_value(config, :bind_host) || host

    %{
      mode: :internal,
      host: host,
      bind_host: bind_host,
      port: 0,
      base_port: nil,
      pool_size: nil
    }
  end

  defp normalize_external_listener(config) do
    host = fetch_value(config, :host)
    bind_host = fetch_value(config, :bind_host) || host
    port = normalize_integer(fetch_value(config, :port))

    cond do
      not is_binary(host) or host == "" ->
        {:error, {:invalid_grpc_listener_config, :missing_host}}

      not is_integer(port) or port <= 0 ->
        {:error, {:invalid_grpc_listener_config, :missing_port}}

      true ->
        {:ok,
         %{
           mode: :external,
           host: host,
           bind_host: bind_host,
           port: port,
           base_port: nil,
           pool_size: nil
         }}
    end
  end

  defp normalize_external_pool_listener(config) do
    host = fetch_value(config, :host)
    bind_host = fetch_value(config, :bind_host) || host
    base_port = normalize_integer(fetch_value(config, :base_port))

    pool_size =
      normalize_integer(fetch_value(config, :pool_size)) || Defaults.grpc_port_pool_size()

    cond do
      not is_binary(host) or host == "" ->
        {:error, {:invalid_grpc_listener_config, :missing_host}}

      not is_integer(base_port) or base_port <= 0 ->
        {:error, {:invalid_grpc_listener_config, :missing_base_port}}

      not is_integer(pool_size) or pool_size <= 0 ->
        {:error, {:invalid_grpc_listener_config, :invalid_pool_size}}

      true ->
        {:ok,
         %{
           mode: :external_pool,
           host: host,
           bind_host: bind_host,
           port: nil,
           base_port: base_port,
           pool_size: pool_size
         }}
    end
  end

  defp normalize_grpc_mode(nil), do: :internal
  defp normalize_grpc_mode(mode) when is_atom(mode), do: mode

  defp normalize_grpc_mode(mode) when is_binary(mode) do
    case String.downcase(mode) do
      "internal" -> :internal
      "external" -> :external
      "external_pool" -> :external_pool
      "external-pool" -> :external_pool
      _ -> :invalid
    end
  end

  defp normalize_grpc_mode(_), do: :invalid

  defp validate_grpc_mode(:internal), do: {:ok, :internal}
  defp validate_grpc_mode(:external), do: {:ok, :external}
  defp validate_grpc_mode(:external_pool), do: {:ok, :external_pool}

  defp validate_grpc_mode(_mode) do
    {:error, {:invalid_grpc_listener_config, :invalid_mode}}
  end

  defp fetch_value(config, key) do
    if Map.has_key?(config, key) do
      Map.get(config, key)
    else
      string_key = Atom.to_string(key)

      if Map.has_key?(config, string_key) do
        Map.get(config, string_key)
      else
        nil
      end
    end
  end

  defp normalize_integer(nil), do: nil
  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> nil
    end
  end

  defp normalize_integer(_), do: nil

  defp normalize_positive_integer(value, default) do
    case normalize_integer(value) do
      int when is_integer(int) and int > 0 -> int
      _ -> default
    end
  end

  defp normalize_non_negative_integer(value, default) do
    case normalize_integer(value) do
      int when is_integer(int) and int >= 0 -> int
      _ -> default
    end
  end

  defp normalize_rogue_cleanup_config(%{} = config) do
    normalized = %{
      enabled: normalize_boolean(fetch_value(config, :enabled), true),
      scripts:
        normalize_string_list(fetch_value(config, :scripts), Defaults.rogue_cleanup_scripts()),
      run_markers:
        normalize_string_list(
          fetch_value(config, :run_markers),
          Defaults.rogue_cleanup_run_markers()
        )
    }

    normalized
  end

  defp normalize_rogue_cleanup_config(config) when is_list(config) do
    config
    |> Enum.into(%{}, fn
      {key, value} -> {key, value}
      other -> {other, nil}
    end)
    |> normalize_rogue_cleanup_config()
  end

  defp normalize_rogue_cleanup_config(_), do: Defaults.rogue_cleanup_defaults()

  defp normalize_boolean(value, _default) when is_boolean(value), do: value
  defp normalize_boolean(_value, default), do: default

  defp normalize_string_list(value, default) when is_list(value) do
    value
    |> Enum.filter(&is_binary/1)
    |> case do
      [] -> default
      list -> list
    end
  end

  defp normalize_string_list(_value, default), do: default

  defp format_grpc_listener_error(reason) do
    "Invalid gRPC listener configuration: #{inspect(reason)}"
  end

  defp default_data_dir do
    priv_dir = :code.priv_dir(:snakepit) |> to_string()
    Path.join([priv_dir, "data"])
  end

  defp normalize_affinity(:hint), do: :hint
  defp normalize_affinity(:strict_queue), do: :strict_queue
  defp normalize_affinity(:strict_fail_fast), do: :strict_fail_fast

  defp normalize_affinity(mode) when is_binary(mode) do
    case String.downcase(mode) do
      "hint" -> :hint
      "strict_queue" -> :strict_queue
      "strict_fail_fast" -> :strict_fail_fast
      _ -> Defaults.default_affinity_mode()
    end
  end

  defp normalize_affinity(_mode), do: Defaults.default_affinity_mode()
end
