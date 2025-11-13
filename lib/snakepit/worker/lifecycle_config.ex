defmodule Snakepit.Worker.LifecycleConfig do
  @moduledoc """
  Canonical configuration for lifecycle-managed workers.

  Pools assemble rich `worker_config` maps that flow through the worker
  pipeline. The lifecycle manager only needs a stable subset of those values
  to make recycling decisions and to start replacement workers. This module
  normalizes that subset into a struct so the contract is explicit and tested.
  """

  @enforce_keys [:pool_name, :worker_module, :adapter_module, :profile_module]
  defstruct [
    :pool_name,
    :pool_identifier,
    :worker_module,
    :adapter_module,
    :worker_profile,
    :profile_module,
    :raw_worker_ttl,
    :worker_ttl_seconds,
    :worker_max_requests,
    :memory_threshold_mb,
    adapter_args: [],
    adapter_env: [],
    base_worker_config: %{}
  ]

  @type t :: %__MODULE__{
          pool_name: term(),
          pool_identifier: atom() | nil,
          worker_module: module(),
          adapter_module: module(),
          worker_profile: atom() | module(),
          profile_module: module(),
          raw_worker_ttl: term(),
          worker_ttl_seconds: :infinity | non_neg_integer(),
          worker_max_requests: :infinity | pos_integer(),
          memory_threshold_mb: nil | pos_integer(),
          adapter_args: list(),
          adapter_env: list(),
          base_worker_config: map()
        }

  @doc """
  Ensures lifecycle config is represented as a `%LifecycleConfig{}` struct.

  Accepts either an existing struct or a worker_config map. The optional
  `pool_name` argument acts as a fallback when the map does not include one.
  """
  @spec ensure(term(), map() | t(), keyword()) :: t()
  def ensure(pool_name, config, opts \\ [])

  def ensure(_pool_name, %__MODULE__{} = config, _opts), do: config
  def ensure(pool_name, config, opts) when is_map(config), do: build(pool_name, config, opts)

  @doc """
  Builds a worker_config map for a replacement worker using the canonical data.
  """
  @spec to_worker_config(t(), String.t()) :: map()
  def to_worker_config(%__MODULE__{} = config, worker_id) when is_binary(worker_id) do
    config.base_worker_config
    |> Map.put(:worker_id, worker_id)
  end

  defp build(pool_name_arg, config, opts) do
    pool_name = pool_name_arg || Map.get(config, :pool_name) || Snakepit.Pool
    pool_identifier = Map.get(config, :pool_identifier) || opts[:pool_identifier]

    worker_module = Map.get(config, :worker_module) || opts[:worker_module] || Snakepit.GRPCWorker

    adapter_module =
      Map.get(config, :adapter_module) ||
        opts[:adapter_module] ||
        Application.get_env(:snakepit, :adapter_module) ||
        Snakepit.Adapters.GRPCPython

    worker_profile_value = Map.get(config, :worker_profile, :process)
    {worker_profile, profile_module} = resolve_profile(worker_profile_value)

    adapter_args = Map.get(config, :adapter_args, [])
    adapter_env = Map.get(config, :adapter_env, [])

    raw_worker_ttl = Map.get(config, :worker_ttl, :infinity)
    worker_ttl_seconds = normalize_ttl(raw_worker_ttl)
    worker_max_requests = Map.get(config, :worker_max_requests, :infinity)
    memory_threshold_mb = Map.get(config, :memory_threshold_mb)

    base_worker_config =
      config
      |> Map.drop([:worker_id, :lifecycle_config])
      |> Map.put(:pool_name, pool_name)
      |> maybe_put(:pool_identifier, pool_identifier)
      |> Map.put(:worker_module, worker_module)
      |> Map.put(:adapter_module, adapter_module)
      |> Map.put(:worker_profile, worker_profile)
      |> Map.put(:adapter_args, adapter_args)
      |> Map.put(:adapter_env, adapter_env)
      |> Map.put(:worker_ttl, raw_worker_ttl)
      |> Map.put(:worker_max_requests, worker_max_requests)
      |> Map.put(:memory_threshold_mb, memory_threshold_mb)

    %__MODULE__{
      pool_name: pool_name,
      pool_identifier: pool_identifier,
      worker_module: worker_module,
      adapter_module: adapter_module,
      worker_profile: worker_profile,
      profile_module: profile_module,
      raw_worker_ttl: raw_worker_ttl,
      worker_ttl_seconds: worker_ttl_seconds,
      worker_max_requests: worker_max_requests,
      memory_threshold_mb: memory_threshold_mb,
      adapter_args: adapter_args,
      adapter_env: adapter_env,
      base_worker_config: base_worker_config
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp resolve_profile(:thread), do: {:thread, Snakepit.WorkerProfile.Thread}
  defp resolve_profile(:process), do: {:process, Snakepit.WorkerProfile.Process}
  defp resolve_profile(module) when is_atom(module), do: {module, module}

  defp normalize_ttl(:infinity), do: :infinity
  defp normalize_ttl({value, :seconds}) when is_integer(value), do: value
  defp normalize_ttl({value, :minutes}) when is_integer(value), do: value * 60
  defp normalize_ttl({value, :hours}) when is_integer(value), do: value * 3600
  defp normalize_ttl({value, :days}) when is_integer(value), do: value * 86_400
  defp normalize_ttl(value) when is_integer(value) and value >= 0, do: value
  defp normalize_ttl(_), do: :infinity
end
