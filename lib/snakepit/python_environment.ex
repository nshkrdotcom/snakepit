defmodule Snakepit.PythonEnvironment do
  @moduledoc """
  Resolve the command used to launch Python workers.

  Snakepit historically executed whatever binary `executable_path/0` returned.
  To support containerised deployments we now resolve a richer command that can
  wrap calls in tools such as `docker exec` while keeping the legacy behaviour
  intact for bare-metal users.

  ## Configuration

      config :snakepit,
        python_environment: :native

  or

      config :snakepit,
        python_environment: {:docker, %{container: "phoenix", python_path: "/opt/venv/bin/python3"}}

  Configuration can also be provided per pool via `pool.python_environment`.
  """

  alias Snakepit.Logger, as: SLog
  alias Snakepit.PythonEnvironment.Command

  @type config_input ::
          nil
          | :native
          | :auto
          | {:docker, map()}
          | %{type: atom(), config: map()}

  @doc """
  Resolve the command for launching Python, taking into account per-worker overrides.

  Returns `{:ok, %Command{}}` or `{:error, reason}`.
  """
  @spec resolve(map()) :: {:ok, Command.t()} | {:error, term()}
  def resolve(worker_config \\ %{}) do
    config =
      Map.get(worker_config, :python_environment) ||
        Application.get_env(:snakepit, :python_environment, :native)

    resolve_from_config(config, worker_config)
  end

  defp resolve_from_config(:native, worker_config),
    do: Snakepit.PythonEnvironment.Native.resolve(worker_config)

  defp resolve_from_config(:auto, worker_config), do: resolve_from_config(:native, worker_config)

  defp resolve_from_config({:docker, config}, worker_config) when is_map(config) do
    Snakepit.PythonEnvironment.Docker.resolve(worker_config, config)
  end

  defp resolve_from_config(%{type: type, config: config}, worker_config) do
    resolve_from_config({type, config}, worker_config)
  end

  defp resolve_from_config(nil, worker_config), do: resolve_from_config(:native, worker_config)

  defp resolve_from_config(other, _worker_config) do
    {:error, {:unknown_python_environment, other}}
  end

  @doc """
  Log a human readable representation of the resolved command.
  """
  @spec log_resolved(Command.t()) :: :ok
  def log_resolved(%Command{} = command) do
    SLog.debug(
      "Python environment command: #{command.executable} #{Enum.join(command.args, " ")} (env=#{length(command.env)})"
    )
  end
end
