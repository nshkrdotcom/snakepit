defmodule Snakepit.PythonRuntime do
  @moduledoc """
  Resolve and manage the Python runtime used by Snakepit.
  """

  @default_config %{
    strategy: :system,
    managed: false,
    python_version: "3.11.8",
    runtime_dir: "priv/snakepit/python",
    cache_dir: "priv/snakepit/python/cache",
    uv_path: nil,
    extra_env: %{"PYTHONNOUSERSITE" => "1"}
  }

  @identity_key {__MODULE__, :runtime_identity}

  def config do
    config =
      :snakepit
      |> Application.get_env(:python, [])
      |> normalize_config_input()

    @default_config
    |> Map.merge(config)
    |> normalize_strategy()
  end

  def managed?(config \\ config()) do
    config.strategy == :uv and config.managed == true
  end

  def executable_path do
    case resolve_executable() do
      {:ok, path, _meta} -> path
      {:error, _reason} -> nil
    end
  end

  def resolve_executable do
    config = config()

    case override_python() do
      {:ok, path} ->
        {:ok, path, %{source: :override}}

      :none ->
        case package_env_python(config) do
          {:ok, path} ->
            {:ok, path, %{source: :package_env}}

          :none ->
            resolve_managed_or_fallback(config)
        end
    end
  end

  defp resolve_managed_or_fallback(config) do
    case managed_executable(config) do
      {:ok, path} -> {:ok, path, %{source: :managed}}
      {:error, :not_managed} -> resolve_fallback(config)
      {:error, reason} -> {:error, reason}
    end
  end

  def runtime_identity do
    case :persistent_term.get(@identity_key, nil) do
      nil -> compute_and_cache_identity()
      identity -> identity
    end
  end

  def runtime_metadata do
    case runtime_identity() do
      {:ok, identity} ->
        %{
          "python_runtime_hash" => identity.hash,
          "python_version" => identity.version,
          "python_platform" => identity.platform
        }

      _ ->
        %{}
    end
  end

  def runtime_env do
    case runtime_identity() do
      {:ok, identity} ->
        [
          {"SNAKEPIT_PYTHON_RUNTIME_HASH", identity.hash},
          {"SNAKEPIT_PYTHON_VERSION", identity.version},
          {"SNAKEPIT_PYTHON_PLATFORM", identity.platform}
        ]

      _ ->
        []
    end
  end

  def missing_reason(config \\ config()) do
    if managed?(config) do
      uv = uv_path(config)

      cond do
        is_nil(uv) ->
          {:error, "uv not found. Install uv or set :python, uv_path: \"/path/to/uv\"."}

        not runtime_installed?(config) ->
          {:error,
           "Managed Python missing in #{runtime_dir(config)}. Run mix snakepit.setup to install it."}

        true ->
          :ok
      end
    else
      :ok
    end
  end

  def install_managed(runner, opts \\ []) do
    config = config()
    uv = uv_path(config)

    cond do
      not managed?(config) ->
        :ok

      is_nil(uv) ->
        {:error, :uv_not_found}

      true ->
        do_install_managed(runner, config, uv, opts)
    end
  end

  defp normalize_strategy(config) do
    strategy =
      case Map.get(config, :strategy) do
        nil ->
          if Map.get(config, :managed) == true do
            :uv
          else
            :system
          end

        value ->
          value
      end

    Map.put(config, :strategy, strategy)
  end

  defp managed_executable(config) do
    if managed?(config) do
      find_managed_executable(config)
    else
      {:error, :not_managed}
    end
  end

  defp find_managed_executable(config) do
    runtime_dir = runtime_dir(config)

    candidates = [
      Path.join([runtime_dir, "bin", "python3"]),
      Path.join([runtime_dir, "bin", "python"])
    ]

    case Enum.find(candidates, &File.exists?/1) do
      nil ->
        find_nested_executable(runtime_dir)

      path ->
        {:ok, path}
    end
  end

  defp find_nested_executable(runtime_dir) do
    nested =
      Path.wildcard(Path.join([runtime_dir, "**", "bin", "python3"])) ++
        Path.wildcard(Path.join([runtime_dir, "**", "bin", "python"]))

    case Enum.find(nested, &File.exists?/1) do
      nil -> {:error, :managed_missing}
      path -> {:ok, path}
    end
  end

  defp do_install_managed(runner, config, uv, opts) do
    runtime_dir = runtime_dir(config)
    cache_dir = cache_dir(config)
    project_root = opts[:project_root] || File.cwd!()

    File.mkdir_p!(runtime_dir)
    File.mkdir_p!(cache_dir)

    env =
      config.extra_env
      |> Map.new()
      |> Map.merge(%{
        "UV_PYTHON_INSTALL_DIR" => runtime_dir,
        "UV_CACHE_DIR" => cache_dir
      })

    args = ["python", "install", config.python_version]

    case runner.cmd(uv, args, cd: project_root, env: env) do
      :ok -> :ok
      {:error, reason} -> {:error, {:uv_install_failed, reason}}
    end
  end

  defp resolve_fallback(_config) do
    cond do
      venv = find_venv_python() -> {:ok, venv, %{source: :venv}}
      system = system_python() -> {:ok, system, %{source: :system}}
      true -> {:error, :not_found}
    end
  end

  defp override_python do
    case Application.get_env(:snakepit, :python_executable) || System.get_env("SNAKEPIT_PYTHON") do
      nil -> :none
      path -> {:ok, path}
    end
  end

  defp package_env_python(config) do
    case python_packages_env_dir(config) do
      nil ->
        :none

      env_dir ->
        case Enum.find(venv_python_paths(env_dir), &File.exists?/1) do
          nil -> :none
          path -> {:ok, path}
        end
    end
  end

  defp python_packages_env_dir(config) do
    case Map.get(python_packages_config(), :env_dir) do
      false -> nil
      nil -> Path.join(runtime_dir(config), "venv")
      value -> Path.expand(value, project_root())
    end
  end

  defp venv_python_paths(env_dir) do
    [
      Path.join([env_dir, "bin", "python3"]),
      Path.join([env_dir, "bin", "python"]),
      Path.join([env_dir, "Scripts", "python.exe"]),
      Path.join([env_dir, "Scripts", "python"])
    ]
  end

  defp python_packages_config do
    :snakepit
    |> Application.get_env(:python_packages, [])
    |> normalize_config_input()
  end

  defp normalize_config_input(nil), do: %{}
  defp normalize_config_input(%{} = map), do: map
  defp normalize_config_input(list) when is_list(list), do: Map.new(list)
  defp normalize_config_input(_), do: %{}

  defp find_venv_python do
    candidates = [
      ".venv/bin/python3",
      "../.venv/bin/python3",
      System.get_env("VIRTUAL_ENV") &&
        Path.join([System.get_env("VIRTUAL_ENV"), "bin", "python3"])
    ]

    Enum.find_value(candidates, fn path ->
      path && File.exists?(Path.expand(path)) && Path.expand(path)
    end)
  end

  defp system_python do
    System.find_executable("python3") || System.find_executable("python")
  end

  defp runtime_dir(config) do
    Path.expand(config.runtime_dir, project_root())
  end

  defp cache_dir(config) do
    Path.expand(config.cache_dir, project_root())
  end

  defp runtime_installed?(config) do
    case managed_executable(config) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp uv_path(config) do
    config.uv_path || System.find_executable("uv")
  end

  defp project_root do
    Application.get_env(:snakepit, :bootstrap_project_root) || File.cwd!()
  end

  defp compute_and_cache_identity do
    identity =
      case resolve_executable() do
        {:ok, path, _meta} -> build_identity(path)
        {:error, reason} -> {:error, reason}
      end

    :persistent_term.put(@identity_key, identity)
    identity
  end

  defp build_identity(path) do
    version = python_version(path)
    platform = system_platform()
    hash = binary_hash(path)

    {:ok, %{path: path, version: version, platform: platform, hash: hash}}
  end

  defp python_version(path) do
    case System.cmd(path, ["-c", "import sys; print(sys.version.split()[0])"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(output)
      _ -> "unknown"
    end
  end

  defp system_platform do
    :erlang.system_info(:system_architecture)
    |> to_string()
  end

  defp binary_hash(path) do
    case File.read(path) do
      {:ok, contents} ->
        :crypto.hash(:sha256, contents)
        |> Base.encode16(case: :lower)

      _ ->
        "unknown"
    end
  end
end
