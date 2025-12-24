defmodule SnakepitLoadtest.MixProject do
  use Mix.Project

  def project do
    [
      app: :snakepit_loadtest,
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
      mod: {SnakepitLoadtest.Application, []},
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
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},

      # Testing
      {:ex_unit_notifier, "~> 1.3", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      "demo.basic": &basic_demo/1,
      "demo.stress": &stress_demo/1,
      "demo.burst": &burst_demo/1,
      "demo.sustained": &sustained_demo/1
    ]
  end

  defp basic_demo(args) do
    workers = parse_workers(args, 10)

    Mix.Task.run("run", [
      "-e",
      """
      # Use the new managed run function
      Snakepit.run_as_script(fn ->
        SnakepitLoadtest.Demos.BasicLoadDemo.run(#{workers})
      end, halt: true)
      """
    ])
  end

  defp stress_demo(args) do
    workers = parse_workers(args, 50)

    Mix.Task.run("run", [
      "-e",
      """
      Snakepit.run_as_script(fn ->
        SnakepitLoadtest.Demos.StressTestDemo.run(#{workers})
      end, halt: true)
      """
    ])
  end

  defp burst_demo(args) do
    workers = parse_workers(args, 100)

    Mix.Task.run("run", [
      "-e",
      """
      Snakepit.run_as_script(fn ->
        SnakepitLoadtest.Demos.BurstLoadDemo.run(#{workers})
      end, halt: true)
      """
    ])
  end

  defp sustained_demo(args) do
    workers = parse_workers(args, 20)

    Mix.Task.run("run", [
      "-e",
      """
      Snakepit.run_as_script(fn ->
        SnakepitLoadtest.Demos.SustainedLoadDemo.run(#{workers})
      end, halt: true)
      """
    ])
  end

  defp parse_workers(args, default) do
    case args do
      [count | _] ->
        case Integer.parse(count) do
          {n, ""} when n > 0 -> n
          _ -> default
        end

      _ ->
        default
    end
  end
end
