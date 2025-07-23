defmodule SnakepitLoadtest.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Telemetry.Metrics.ConsoleReporter,
       metrics: telemetry_metrics(),
       device: :stdio}
    ]

    opts = [strategy: :one_for_one, name: SnakepitLoadtest.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp telemetry_metrics do
    [
      Telemetry.Metrics.counter("snakepit.execute.stop.duration"),
      Telemetry.Metrics.summary("snakepit.execute.stop.duration"),
      Telemetry.Metrics.counter("snakepit.execute.exception.duration"),
      Telemetry.Metrics.counter("snakepit.pool.checkout.stop.duration"),
      Telemetry.Metrics.summary("snakepit.pool.checkout.stop.duration")
    ]
  end
end