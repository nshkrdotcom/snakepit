defmodule SnakepitShowcase.MixProject do
  use Mix.Project

  def project do
    [
      app: :snakepit_showcase,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {SnakepitShowcase.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Use Snakepit from parent directory
      {:snakepit, path: "../../"},
      
      # Core dependencies
      {:jason, "~> 1.4"},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},
      
      # Testing
      {:ex_unit_notifier, "~> 1.3", only: :test},
      {:mock, "~> 0.3.0", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      demo: ["run"],
      "demo.all": ["run --eval 'Snakepit.run_as_script(fn -> SnakepitShowcase.DemoRunner.run_all() end)'"],
      "demo.interactive": ["run --eval 'Snakepit.run_as_script(fn -> SnakepitShowcase.DemoRunner.interactive() end)'"],
      "demo.basic": ["run --eval 'Snakepit.run_as_script(fn -> SnakepitShowcase.Demos.BasicDemo.run() end)'"],
      "demo.session": ["run --eval 'Snakepit.run_as_script(fn -> SnakepitShowcase.Demos.SessionDemo.run() end)'"],
      "demo.streaming": ["run --eval 'Snakepit.run_as_script(fn -> SnakepitShowcase.Demos.StreamingDemo.run() end)'"],
      "demo.concurrent": ["run --eval 'Snakepit.run_as_script(fn -> SnakepitShowcase.Demos.ConcurrentDemo.run() end)'"],
      "demo.variables": ["run --eval 'Snakepit.run_as_script(fn -> SnakepitShowcase.Demos.VariablesDemo.run() end)'"],
      "demo.binary": ["run --eval 'Snakepit.run_as_script(fn -> SnakepitShowcase.Demos.BinaryDemo.run() end)'"],
      "demo.ml_workflow": ["run --eval 'Snakepit.run_as_script(fn -> SnakepitShowcase.Demos.MLWorkflowDemo.run() end)'"],
      "demo.execution_modes": ["run --eval 'Snakepit.run_as_script(fn -> SnakepitShowcase.Demos.ExecutionModesDemo.run() end)'"]
    ]
  end
end