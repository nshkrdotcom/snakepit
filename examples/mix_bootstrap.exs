defmodule Snakepit.Examples.Bootstrap do
  @moduledoc false

  @spec ensure_mix!([term()]) :: :ok
  def ensure_mix!(deps) when is_list(deps) do
    mix_started =
      case Application.ensure_all_started(:mix) do
        {:ok, _apps} -> true
        {:error, {:already_started, :mix}} -> true
        _ -> false
      end

    project_loaded? =
      mix_started and
        Code.ensure_loaded?(Mix.Project) and
        function_exported?(Mix.Project, :get, 0) and
        Mix.Project.get() != nil

    unless project_loaded? do
      Mix.install(deps)
    end

    :ok
  end
end
