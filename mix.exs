defmodule Snakepit.MixProject do
  use Mix.Project

  def project do
    [
      app: :snakepit,
      version: "0.1.1",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      description:
        "High-performance pooler and session manager for external language integrations",
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
      description:
        "High-performance pooler and session manager for external language integrations",
      licenses: ["MIT"],
      maintainers: ["NSHkr <ZeroTrust@NSHkr.com>"],
      links: %{"GitHub" => "https://github.com/nshkrdotcom/snakepit"},
      files: ~w(lib priv .formatter.exs mix.exs README* LICENSE* CHANGELOG* DIAGS*),
      exclude_patterns: ["priv/plts", "priv/python/__pycache__"]
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
      extras: ["README.md", "DIAGS.md"],
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
end
