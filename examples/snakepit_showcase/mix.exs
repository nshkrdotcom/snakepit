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
      "demo.all": ["run -e SnakepitShowcase.DemoRunner.run_all()"],
      "demo.interactive": ["run -e SnakepitShowcase.DemoRunner.interactive()"],
      "demo.basic": ["run -e SnakepitShowcase.Demos.BasicDemo.run()"],
      "demo.session": ["run -e SnakepitShowcase.Demos.SessionDemo.run()"],
      "demo.streaming": ["run -e SnakepitShowcase.Demos.StreamingDemo.run()"],
      "demo.concurrent": ["run -e SnakepitShowcase.Demos.ConcurrentDemo.run()"],
      "demo.variables": ["run -e SnakepitShowcase.Demos.VariablesDemo.run()"],
      "demo.binary": ["run -e SnakepitShowcase.Demos.BinaryDemo.run()"],
      "demo.ml_workflow": ["run -e SnakepitShowcase.Demos.MLWorkflowDemo.run()"],
      "demo.execution_modes": ["run -e SnakepitShowcase.Demos.ExecutionModesDemo.run()"]
    ]
  end
end