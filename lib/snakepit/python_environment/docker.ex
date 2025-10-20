defmodule Snakepit.PythonEnvironment.Docker do
  @moduledoc """
  Execute Python inside an existing Docker container using `docker exec`.

  The container must already be running. Configuration can optionally map host
  paths to container paths so Snakepit can locate the gRPC server script within
  the containerised filesystem.
  """

  alias Snakepit.Logger, as: SLog
  alias Snakepit.PythonEnvironment.Command

  @default_exec ["exec", "-i"]
  @default_python "python3"

  @spec resolve(map(), map()) :: {:ok, Command.t()} | {:error, term()}
  def resolve(worker_config, config) do
    with {:ok, docker} <- resolve_docker_binary(config),
         {:ok, container} <- resolve_container(config),
         python_path <- resolve_python_path(worker_config, config) do
      command =
        %Command{
          executable: docker,
          args: build_args(container, config, python_path),
          env: normalize_env(config),
          path_mappings: build_path_mappings(config),
          set_host_cwd?: false,
          metadata: %{
            environment: :docker,
            container: container,
            python_path: python_path
          }
        }

      maybe_log_validation(command, config)

      {:ok, command}
    end
  end

  defp resolve_docker_binary(config) do
    docker_path =
      config
      |> Map.get(:docker_binary, "docker")
      |> find_executable()

    case docker_path do
      nil -> {:error, :docker_not_found}
      path -> {:ok, path}
    end
  end

  defp find_executable(path) when path in ["docker", "docker.exe"],
    do: System.find_executable(path)

  defp find_executable(path) do
    cond do
      File.exists?(path) -> Path.expand(path)
      true -> System.find_executable(path)
    end
  end

  defp resolve_container(config) do
    case Map.get(config, :container) || Map.get(config, :container_name) do
      nil -> {:error, :docker_container_not_configured}
      container -> {:ok, container}
    end
  end

  defp resolve_python_path(worker_config, config) do
    Map.get(worker_config, :python_path) ||
      Map.get(worker_config, :python_executable) ||
      Map.get(config, :python_path, @default_python)
  end

  defp build_args(container, config, python_path) do
    exec_prefix =
      config
      |> Map.get(:exec_prefix, [])
      |> List.wrap()

    exec_flags =
      config
      |> Map.get(:exec_flags, @default_exec)
      |> List.wrap()

    pre_python =
      config
      |> Map.get(:pre_python_args, [])
      |> List.wrap()

    python_args =
      config
      |> Map.get(:python_args, [])
      |> List.wrap()

    exec_prefix ++ exec_flags ++ [container] ++ pre_python ++ [python_path | python_args]
  end

  defp normalize_env(config) do
    config
    |> Map.get(:env, [])
    |> Enum.map(fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), to_string(value)}
      {key, value} -> {to_string(key), to_string(value)}
      other -> other
    end)
  end

  defp build_path_mappings(config) do
    cond do
      mappings = Map.get(config, :path_mappings) ->
        List.wrap(mappings)

      project = Map.get(config, :project_root) ->
        host = Map.get(project, :host, File.cwd!())
        container = Map.fetch!(project, :container)
        [%{from: host, to: container}]

      true ->
        []
    end
  end

  defp maybe_log_validation(command, config) do
    if Map.get(config, :validate?, false) do
      case validate_container(command.metadata.container) do
        :ok ->
          SLog.debug("Docker container #{command.metadata.container} is running")

        {:error, reason} ->
          SLog.warning(
            "Docker container #{command.metadata.container} validation failed: #{inspect(reason)}"
          )
      end
    end
  end

  defp validate_container(container) do
    case System.cmd("docker", ["inspect", "-f", "{{.State.Running}}", container]) do
      {"true\n", 0} -> :ok
      {"false\n", 0} -> {:error, :container_not_running}
      _ -> {:error, :container_not_found}
    end
  end
end
