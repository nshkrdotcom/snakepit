defmodule Snakepit.MixProject do
  use Mix.Project

  @version "0.8.2"
  @source_url "https://github.com/nshkrdotcom/snakepit"

  def project do
    [
      app: :snakepit,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      description: description(),
      package: package(),
      deps: deps(),
      dialyzer: dialyzer(),
      docs: docs(),
      aliases: aliases(),
      name: "Snakepit",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :telemetry],
      mod: {Snakepit.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.0"},
      {:grpc, "~> 0.11.5"},
      {:protobuf, "~> 0.15.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:telemetry_metrics_prometheus, "~> 1.1"},
      {:opentelemetry, "~> 1.3"},
      {:opentelemetry_exporter, "~> 1.6"},
      {:opentelemetry_telemetry, "~> 1.0"},
      {:stream_data, "~> 1.0", only: [:test]},
      {:supertester, "~> 0.4.0", only: :test},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    """
    High-performance pooler and session manager for external language integrations.
    Supports Python, Node.js, Ruby, and more with gRPC streaming, session management,
    and production-ready process cleanup.
    """
  end

  defp package do
    [
      name: "snakepit",
      description: description(),
      licenses: ["MIT"],
      maintainers: ["nshkrdotcom"],
      links: %{
        "GitHub" => @source_url,
        "Online documentation" => "https://hexdocs.pm/snakepit",
        "Architecture Guide" => "https://hexdocs.pm/snakepit/ARCHITECTURE.html",
        "gRPC Streaming Guide" => "https://hexdocs.pm/snakepit/README_GRPC.html",
        "Telemetry Guide" => "https://hexdocs.pm/snakepit/TELEMETRY.html",
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      files: [
        # Core library
        "lib",
        "priv/proto",
        "priv/python/*.py",
        "priv/python/requirements*.txt",
        "priv/python/setup.py",
        "priv/python/snakepit_bridge",
        "priv/python/README_THREADING.md",
        "assets",
        "guides",
        # Documentation
        "docs/GRPC_QUICK_REFERENCE.md",
        "docs/TEST_AND_EXAMPLE_STATUS.md",
        "docs/EXAMPLE_TEST_RESULTS.md",
        "docs/ECOSYSTEM_ARCHITECTURE.md",
        "docs/DSPEX_PRODUCTION_STRATEGY.md",
        "docs/PRODUCTION_DEPLOYMENT_CHECKLIST.md",
        "docs/migration_v0.5_to_v0.6.md",
        "docs/performance_benchmarks.md",
        "docs/telemetry_events.md",
        "docs/guides",
        "docs/code-standards",
        # Build configuration
        ".formatter.exs",
        "mix.exs",
        # Root documentation
        "README.md",
        "ARCHITECTURE.md",
        "DIAGRAMS.md",
        "CHANGELOG.md",
        "TELEMETRY.md",
        "LOG_LEVEL_CONFIGURATION.md",
        "README_GRPC.md",
        "README_BIDIRECTIONAL_TOOL_BRIDGE.md",
        "README_PROCESS_MANAGEMENT.md",
        "README_TESTING.md",
        "LICENSE*"
      ],
      exclude_patterns: [
        "**/__pycache__",
        "**/*.pyc",
        "**/*.egg-info",
        "**/*.bak",
        "priv/plts",
        "priv/data",
        "docs/archive",
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
      name: "Snakepit",
      source_ref: "v#{@version}",
      source_url: @source_url,
      homepage_url: @source_url,
      assets: %{"assets" => "assets"},
      logo: "assets/snakepit-logo.svg",
      extras: [
        # Main documentation
        "README.md",
        "CHANGELOG.md",

        # Getting started
        {"guides/INSTALLATION.md", title: "Installation Guide"},
        {"docs/migration_v0.5_to_v0.6.md", title: "Migration Guide (v0.5 to v0.6)"},

        # Core documentation
        {"ARCHITECTURE.md", title: "System Architecture"},
        {"DIAGRAMS.md", title: "Architecture Diagrams"},

        # ML Workload Guides
        {"guides/hardware-detection.md", title: "Hardware Detection"},
        {"guides/crash-recovery.md", title: "Crash Recovery"},
        {"guides/error-handling.md", title: "Error Handling"},
        {"guides/ml-telemetry.md", title: "ML Telemetry"},

        # Feature documentation
        {"README_GRPC.md", title: "gRPC Streaming Guide"},
        {"README_BIDIRECTIONAL_TOOL_BRIDGE.md", title: "Bidirectional Tool Bridge"},
        {"README_PROCESS_MANAGEMENT.md", title: "Process Management"},
        {"README_TESTING.md", title: "Testing Guide"},
        {"TELEMETRY.md", title: "Telemetry & Observability"},
        {"LOG_LEVEL_CONFIGURATION.md", title: "Log Level Configuration"},

        # Reference documentation
        {"docs/GRPC_QUICK_REFERENCE.md", title: "gRPC Quick Reference"},
        {"docs/telemetry_events.md", title: "Telemetry Events Reference"},
        {"docs/performance_benchmarks.md", title: "Performance Benchmarks"},
        {"docs/PRODUCTION_DEPLOYMENT_CHECKLIST.md", title: "Production Deployment Checklist"},

        # Guides
        {"docs/guides/writing_thread_safe_adapters.md", title: "Writing Thread-Safe Adapters"},
        {"priv/python/README_THREADING.md", title: "Python Threading Guide"},

        # Testing
        {"docs/TEST_AND_EXAMPLE_STATUS.md", title: "Test & Example Status"},
        {"docs/EXAMPLE_TEST_RESULTS.md", title: "Example Test Results"},
        {"docs/code-standards/test-architecture-supertester.md", title: "Test Architecture"},

        # Ecosystem
        {"docs/ECOSYSTEM_ARCHITECTURE.md", title: "Ecosystem Architecture"},
        {"docs/DSPEX_PRODUCTION_STRATEGY.md", title: "DSPex Production Strategy"},

        # Archive
        {"docs/archive/design-process/README_UNIFIED_GRPC_BRIDGE.md",
         title: "Unified gRPC Bridge (Archived)"},

        # License
        "LICENSE"
      ],
      groups_for_extras: [
        "Getting Started": [
          "README.md",
          "guides/INSTALLATION.md",
          "docs/migration_v0.5_to_v0.6.md"
        ],
        Features: [
          "README_GRPC.md",
          "README_BIDIRECTIONAL_TOOL_BRIDGE.md",
          "README_PROCESS_MANAGEMENT.md",
          "TELEMETRY.md",
          "LOG_LEVEL_CONFIGURATION.md"
        ],
        Architecture: [
          "ARCHITECTURE.md",
          "DIAGRAMS.md"
        ],
        "ML Workloads": [
          "guides/hardware-detection.md",
          "guides/crash-recovery.md",
          "guides/error-handling.md",
          "guides/ml-telemetry.md"
        ],
        Guides: [
          "docs/guides/writing_thread_safe_adapters.md",
          "priv/python/README_THREADING.md"
        ],
        Testing: [
          "README_TESTING.md",
          "docs/TEST_AND_EXAMPLE_STATUS.md",
          "docs/EXAMPLE_TEST_RESULTS.md",
          "docs/code-standards/test-architecture-supertester.md"
        ],
        Reference: [
          "docs/GRPC_QUICK_REFERENCE.md",
          "docs/telemetry_events.md",
          "docs/performance_benchmarks.md",
          "docs/PRODUCTION_DEPLOYMENT_CHECKLIST.md"
        ],
        Ecosystem: [
          "docs/ECOSYSTEM_ARCHITECTURE.md",
          "docs/DSPEX_PRODUCTION_STRATEGY.md"
        ],
        "Release Notes": [
          "CHANGELOG.md"
        ],
        License: [
          "LICENSE"
        ],
        Archive: [
          "docs/archive/design-process/README_UNIFIED_GRPC_BRIDGE.md"
        ]
      ],
      groups_for_modules: [
        "Core API": [
          Snakepit,
          Snakepit.Adapter
        ],
        "Pool Management": [
          Snakepit.Pool,
          Snakepit.Pool.WorkerSupervisor,
          Snakepit.Pool.Worker.Starter
        ],
        Workers: [
          Snakepit.GRPCWorker
        ],
        "Session & State": [
          Snakepit.Bridge.SessionStore,
          Snakepit.Bridge.Session
        ],
        Adapters: [
          Snakepit.Adapters.GRPCPython
        ],
        "Process Management": [
          Snakepit.Pool.ProcessRegistry,
          Snakepit.Pool.ApplicationCleanup,
          Snakepit.ProcessKiller
        ],
        Registry: [
          Snakepit.Pool.Registry,
          Snakepit.Pool.Worker.StarterRegistry
        ],
        "gRPC & Bridge": [
          Snakepit.GRPC.BridgeServer,
          Snakepit.GRPC.Client,
          Snakepit.GRPC.Endpoint,
          Snakepit.Bridge.ToolRegistry
        ],
        Hardware: [
          Snakepit.Hardware,
          Snakepit.Hardware.Detector,
          Snakepit.Hardware.CPUDetector,
          Snakepit.Hardware.CUDADetector,
          Snakepit.Hardware.MPSDetector,
          Snakepit.Hardware.ROCmDetector,
          Snakepit.Hardware.Selector
        ],
        Reliability: [
          Snakepit.CircuitBreaker,
          Snakepit.HealthMonitor,
          Snakepit.RetryPolicy,
          Snakepit.Executor
        ],
        "ML Errors": [
          Snakepit.Error.Shape,
          Snakepit.Error.Device,
          Snakepit.Error.Parser
        ],
        Telemetry: [
          Snakepit.Telemetry,
          Snakepit.Telemetry.Events,
          Snakepit.Telemetry.GrpcStream,
          Snakepit.Telemetry.GPUProfiler,
          Snakepit.Telemetry.Span,
          Snakepit.Telemetry.Naming,
          Snakepit.Telemetry.SafeMetadata,
          Snakepit.Telemetry.Control,
          Snakepit.Telemetry.Correlation,
          Snakepit.Telemetry.Handlers.Logger,
          Snakepit.Telemetry.Handlers.Metrics,
          Snakepit.TelemetryMetrics
        ],
        Utilities: [
          Snakepit.RunID,
          Snakepit.Config,
          Snakepit.Error
        ]
      ],
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
          startOnLoad: false,
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

        // ExDoc renders ```mermaid blocks as <pre><code class="mermaid">
        // Transform them into <div class="mermaid"> for proper rendering
        document.querySelectorAll("pre code.mermaid").forEach(function (codeEl) {
          var pre = codeEl.parentElement;
          var div = document.createElement("div");
          div.className = "mermaid";
          div.textContent = codeEl.textContent;
          pre.parentElement.replaceChild(div, pre);
        });

        // Now render all mermaid diagrams
        mermaid.init(undefined, document.querySelectorAll(".mermaid"));
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
