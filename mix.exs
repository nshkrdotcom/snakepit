defmodule Snakepit.MixProject do
  use Mix.Project

  def project do
    [
      app: :snakepit,
      version: "0.0.1",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      description: "High-performance pooler and session manager",
      package: package(),
      deps: deps(),
      dialyzer: dialyzer(),
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Snakepit.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.0"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      description: "High-performance pooler and session manager",
      licenses: ["MIT"],
      maintainers: ["NSHkr <ZeroTrust@NSHkr.com>"],
      links: %{"GitHub" => "https://github.com/nshkrdotcom/snakepit"},
      files: ~w(lib priv .formatter.exs mix.exs README* LICENSE* CHANGELOG*)
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix],
      plt_core_path: "priv/plts",
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"]
    ]
  end
end
