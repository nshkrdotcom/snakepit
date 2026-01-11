defmodule Snakepit.Worker.Configuration do
  @moduledoc false

  alias Snakepit.Adapters.GRPCPython
  alias Snakepit.Config
  alias Snakepit.Logger, as: SLog
  alias Snakepit.Pool.ProcessRegistry

  @log_category :grpc

  def resolve_pool_identifier(opts, pool_name) do
    case Keyword.get(opts, :pool_identifier) do
      identifier when is_atom(identifier) ->
        identifier

      identifier when is_binary(identifier) ->
        string_to_existing_atom_safe(identifier)

      _ ->
        infer_pool_identifier(pool_name)
    end
  end

  def normalize_worker_config(config, worker_module, pool_name, adapter_module, pool_identifier) do
    config
    |> Map.put(:worker_module, worker_module)
    |> Map.put_new(:adapter_module, adapter_module)
    |> Map.put(:pool_name, pool_name)
    |> maybe_put_pool_identifier(pool_identifier)
  end

  def build_spawn_config(
        adapter,
        worker_config,
        heartbeat_config,
        port,
        elixir_address,
        worker_id
      ) do
    python_executable = adapter.executable_path()
    adapter_args = resolve_adapter_args(adapter, worker_config)
    adapter_env = worker_config |> Map.get(:adapter_env, []) |> merge_with_default_adapter_env()
    heartbeat_env_json = encode_heartbeat_env(heartbeat_config)
    ready_file = build_ready_file(worker_id)
    script_path = determine_script_path(adapter, adapter_args)
    args = build_spawn_args(adapter_args, port, elixir_address)
    env_entries = build_env_entries(adapter_env, heartbeat_env_json, ready_file)

    SLog.info(
      @log_category,
      "Starting gRPC server: #{python_executable} #{script_path || ""} #{Enum.join(args, " ")}"
    )

    %{
      executable: python_executable,
      script_path: script_path,
      args: args,
      process_group?: process_group_spawn?(),
      env_entries: env_entries,
      ready_file: ready_file
    }
  end

  defp string_to_existing_atom_safe(identifier) do
    String.to_existing_atom(identifier)
  rescue
    ArgumentError -> nil
  end

  defp infer_pool_identifier(pool_name) when is_atom(pool_name), do: pool_name

  defp infer_pool_identifier(pool_name) when is_pid(pool_name) do
    case Process.info(pool_name, :registered_name) do
      {:registered_name, name} when is_atom(name) -> name
      _ -> nil
    end
  end

  defp infer_pool_identifier(_), do: nil

  defp maybe_put_pool_identifier(metadata, nil), do: metadata

  defp maybe_put_pool_identifier(metadata, identifier),
    do: Map.put(metadata, :pool_identifier, identifier)

  defp resolve_adapter_args(adapter, worker_config) do
    worker_adapter_args = Map.get(worker_config, :adapter_args, [])

    if worker_adapter_args == [] do
      adapter.script_args() || []
    else
      worker_adapter_args
    end
  end

  defp determine_script_path(adapter, adapter_args) do
    if Enum.any?(adapter_args, fn arg ->
         is_binary(arg) and String.contains?(arg, "--max-workers")
       end) do
      app_dir = Application.app_dir(:snakepit)
      Path.join([app_dir, "priv", "python", "grpc_server_threaded.py"])
    else
      adapter.script_path()
    end
  end

  defp build_spawn_args(adapter_args, port, elixir_address) do
    adapter_args
    |> maybe_add_arg("--port", to_string(port))
    |> maybe_add_arg("--elixir-address", elixir_address)
    |> add_run_id_arg()
    |> add_instance_name_arg()
    |> add_instance_token_arg()
  end

  defp build_ready_file(worker_id) do
    base_dir = System.tmp_dir() || File.cwd!()

    safe_worker_id =
      worker_id
      |> to_string()
      |> String.replace(~r/[^a-zA-Z0-9_.-]/, "_")

    unique = :erlang.unique_integer([:positive, :monotonic])
    Path.join(base_dir, "snakepit_ready_#{safe_worker_id}_#{unique}")
  end

  defp maybe_add_arg(args, flag, value) do
    if Enum.any?(args, &String.contains?(&1, flag)) do
      args
    else
      args ++ [flag, value]
    end
  end

  defp add_run_id_arg(args) do
    run_id = ProcessRegistry.get_beam_run_id()
    args ++ ["--snakepit-run-id", run_id]
  end

  defp add_instance_name_arg(args) do
    case Config.instance_name_identifier() do
      name when is_binary(name) and name != "" ->
        maybe_add_arg(args, "--snakepit-instance-name", name)

      _ ->
        args
    end
  end

  defp add_instance_token_arg(args) do
    case Config.instance_token_identifier() do
      token when is_binary(token) and token != "" ->
        maybe_add_arg(args, "--snakepit-instance-token", token)

      _ ->
        args
    end
  end

  defp process_group_spawn? do
    Application.get_env(:snakepit, :process_group_kill, true) and
      Snakepit.ProcessKiller.process_group_supported?()
  end

  defp build_env_entries(adapter_env, heartbeat_env_json, ready_file) do
    adapter_env
    |> maybe_put_heartbeat_env(heartbeat_env_json)
    |> maybe_put_ready_file_env(ready_file)
    |> maybe_put_log_level_env()
  end

  defp encode_heartbeat_env(config) when is_map(config) do
    config
    |> Map.new()
    |> Map.take([
      :enabled,
      :ping_interval_ms,
      :timeout_ms,
      :max_missed_heartbeats,
      :initial_delay_ms,
      :dependent
    ])
    |> Enum.reduce(%{}, fn
      {:ping_interval_ms, value}, acc -> Map.put(acc, "interval_ms", value)
      {key, value}, acc -> Map.put(acc, to_string(key), value)
    end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> case do
      %{} = map when map == %{} -> nil
      map -> Jason.encode!(map)
    end
  end

  defp normalize_adapter_env_entries(nil), do: []

  defp normalize_adapter_env_entries(env) when is_map(env) do
    env
    |> Map.to_list()
    |> normalize_adapter_env_entries()
  end

  defp normalize_adapter_env_entries(env) when is_list(env) do
    Enum.flat_map(env, fn
      {key, value} -> [{to_string(key), to_string(value)}]
      key when is_binary(key) -> [{key, ""}]
      key when is_atom(key) -> [{Atom.to_string(key), ""}]
      _ -> []
    end)
  end

  defp merge_with_default_adapter_env(env) do
    existing = normalize_adapter_env_entries(env)
    defaults = default_adapter_env()

    existing_keys =
      existing
      |> Enum.map(fn {key, _} -> String.downcase(key) end)
      |> MapSet.new()

    defaults
    |> Enum.reject(fn {key, _value} -> MapSet.member?(existing_keys, String.downcase(key)) end)
    |> Kernel.++(existing)
  end

  defp default_adapter_env do
    priv_python =
      :code.priv_dir(:snakepit)
      |> to_string()
      |> Path.join("python")

    repo_priv_python =
      Path.join(File.cwd!(), "priv/python")

    snakebridge_priv_python =
      case :code.priv_dir(:snakebridge) do
        {:error, _} -> nil
        priv_dir -> Path.join([to_string(priv_dir), "python"])
      end

    path_sep = path_separator()

    pythonpath =
      [System.get_env("PYTHONPATH"), priv_python, repo_priv_python, snakebridge_priv_python]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()
      |> Enum.join(path_sep)

    interpreter =
      Application.get_env(:snakepit, :python_executable) ||
        System.get_env("SNAKEPIT_PYTHON") ||
        GRPCPython.executable_path()

    process_group_env =
      if Application.get_env(:snakepit, :process_group_kill, true) and
           Snakepit.ProcessKiller.process_group_supported?() do
        [{"SNAKEPIT_PROCESS_GROUP", "1"}]
      else
        []
      end

    base =
      []
      |> maybe_cons("PYTHONPATH", pythonpath)
      |> maybe_cons("SNAKEPIT_PYTHON", interpreter)

    extra_env =
      Snakepit.PythonRuntime.config()
      |> Map.get(:extra_env, %{})
      |> normalize_adapter_env_entries()

    base ++ process_group_env ++ extra_env ++ Snakepit.PythonRuntime.runtime_env()
  end

  defp maybe_cons(acc, _key, value) when value in [nil, ""], do: acc
  defp maybe_cons(acc, key, value), do: [{key, value} | acc]

  defp path_separator do
    case :os.type() do
      {:win32, _} -> ";"
      _ -> ":"
    end
  end

  defp elixir_to_python_level(:debug), do: "debug"
  defp elixir_to_python_level(:info), do: "info"
  defp elixir_to_python_level(:warning), do: "warning"
  defp elixir_to_python_level(:error), do: "error"
  defp elixir_to_python_level(:none), do: "none"
  defp elixir_to_python_level(_), do: "error"

  defp maybe_put_heartbeat_env(entries, nil), do: entries

  defp maybe_put_heartbeat_env(entries, json),
    do: maybe_put_env(entries, "SNAKEPIT_HEARTBEAT_CONFIG", json)

  defp maybe_put_ready_file_env(entries, ready_file),
    do: maybe_put_env(entries, "SNAKEPIT_READY_FILE", ready_file)

  defp maybe_put_log_level_env(entries) do
    level = Application.get_env(:snakepit, :log_level, :error)
    maybe_put_env(entries, "SNAKEPIT_LOG_LEVEL", elixir_to_python_level(level))
  end

  defp maybe_put_env(entries, _key, value) when value in [nil, ""], do: entries

  defp maybe_put_env(entries, key, value) do
    filtered =
      Enum.reject(entries, fn {existing_key, _value} ->
        String.downcase(existing_key) == String.downcase(key)
      end)

    [{key, value} | filtered]
  end
end
