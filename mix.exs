defmodule Snakepit.MixProject do
  use Mix.Project

  def project do
    [
      app: :snakepit,
      version: "0.4.2",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      description:
        "High-performance pooler and session manager for external language integrations",
      package: package(),
      deps: deps(),
      dialyzer: dialyzer(),
      docs: docs(),
      aliases: aliases()
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
      {:grpc, "~> 0.10.2"},
      {:protobuf, "~> 0.14.1"},
      {:stream_data, "~> 1.0", only: [:test]},
      {:supertester, "~> 0.1.0", only: :test},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      description:
        "High-performance pooler and session manager for external language integrations",
      licenses: ["MIT"],
      maintainers: ["NSHkr <ZeroTrust@NSHkr.com>"],
      links: %{"GitHub" => "https://github.com/nshkrdotcom/snakepit"},
      files: [
        "lib",
        "priv/proto",
        "priv/python/*.py",
        "priv/python/requirements*.txt",
        "priv/python/setup.py",
        "priv/python/snakepit_bridge",
        "assets",
        "guides",
        ".formatter.exs",
        "mix.exs",
        "README*",
        "LICENSE*",
        "CHANGELOG*",
        "DIAGS*",
        "ARCHITECTURE*",
        "priv/python/BINARY_SERIALIZATION.md"
      ],
      exclude_patterns: [
        "**/__pycache__",
        "**/*.pyc",
        "**/*.egg-info",
        "**/*.bak",
        "priv/plts",
        "priv/python/snakepit_bridge/__pycache__",
        "priv/python/snakepit_bridge/adapters/__pycache__",
        "priv/python/snakepit_bridge/adapters/showcase/__pycache__",
        "priv/python/snakepit_bridge/adapters/showcase/handlers/__pycache__"
      ]
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
      extras: [
        "README.md",
        "README_GRPC.md",
        "README_BIDIRECTIONAL_TOOL_BRIDGE.md",
        "README_PROCESS_MANAGEMENT.md",
        "README_TESTING.md",
        "README_UNIFIED_GRPC_BRIDGE.md",
        "ARCHITECTURE.md",
        "DIAGS.md",
        "DIAGS2.md",
        "priv/python/BINARY_SERIALIZATION.md"
      ],
      assets: %{"assets" => "assets"},
      logo: "assets/snakepit-logo.svg",
      before_closing_head_tag: &docs_before_closing_head_tag/1,
      before_closing_body_tag: &docs_before_closing_body_tag/1
    ]
  end

  defp docs_before_closing_head_tag(:html) do
    """
    <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
    """
  end

  defp docs_before_closing_head_tag(_), do: ""

  defp docs_before_closing_body_tag(:html) do
    """
    <script>
      document.addEventListener("DOMContentLoaded", function () {
        mermaid.initialize({
          startOnLoad: true,
          theme: "default",
          themeVariables: {
            primaryColor: "#6366f1",
            primaryTextColor: "#fff",
            primaryBorderColor: "#4f46e5",
            lineColor: "#6b7280",
            sectionBkgColor: "#f3f4f6",
            altSectionBkgColor: "#ffffff",
            gridColor: "#e5e7eb",
            secondaryColor: "#e0e7ff",
            tertiaryColor: "#f1f5f9"
          }
        });
      });
    </script>
    """
  end

  defp docs_before_closing_body_tag(_), do: ""

  defp aliases do
    [
      "grpc.gen": [
        "cmd mkdir -p lib/snakepit/grpc/generated",
        "cmd protoc --elixir_out=plugins=grpc:./lib/snakepit/grpc/generated --proto_path=priv/proto priv/proto/snakepit_bridge.proto"
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
