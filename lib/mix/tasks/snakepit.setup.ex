defmodule Mix.Tasks.Snakepit.Setup do
  @moduledoc """
  Bootstrap the Snakepit development environment.

  This task mirrors `make bootstrap` and prepares both the Elixir and Python
  tooling so tests can run without manual steps.
  """

  use Mix.Task

  @shortdoc "Provision Mix deps, Python venvs, and gRPC stubs"

  @impl true
  def run(_args) do
    case Snakepit.Bootstrap.run() do
      :ok -> :ok
      {:error, reason} -> Mix.raise("Snakepit bootstrap failed: #{inspect(reason)}")
    end
  end
end
