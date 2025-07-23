defmodule SnakepitShowcase.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Start Task Supervisor for running demos
      {Task.Supervisor, name: SnakepitShowcase.TaskSupervisor}
    ]

    opts = [strategy: :one_for_one, name: SnakepitShowcase.Supervisor]
    Supervisor.start_link(children, opts)
  end
end