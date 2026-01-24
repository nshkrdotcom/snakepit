defmodule Snakepit.MixProject do
  use Mix.Project

  @version "0.11.1"
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
      {:grpc, "0.11.5"},
      # {:grpc_core,
      # github: "nshkrdotcom/grpc",
      # ref: "3cec4f8c010c7869e20ccc5068872e29faecd1a9",
      # sparse: "grpc_core",
      # override: true},
      # {:grpc_server,
      # github: "nshkrdotcom/grpc",
      # ref: "3cec4f8c010c7869e20ccc5068872e29faecd1a9",
      # sparse: "grpc_server",
      # override: true},
      # {:grpc_client,
      # github: "nshkrdotcom/grpc",
      # ref: "3cec4f8c010c7869e20ccc5068872e29faecd1a9",
      # sparse: "grpc_client",
      # override: true},

      # {:protobuf, "0.16.0", override: true},
      # {:protobuf,
      # github: "nshkrdotcom/protobuf",
      # ref: "250e4693ce50f4ef897fcb6e27e777dc6bdfa75c",
      # override: true},

      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:telemetry_metrics_prometheus, "~> 1.1"},
      {:opentelemetry, "~> 1.3"},
      {:opentelemetry_exporter, "~> 1.6"},
      {:opentelemetry_telemetry, "~> 1.0"},
      {:stream_data, "~> 1.0", only: [:test]},
      {:supertester, "~> 0.5.1", only: :test},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
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
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      files: [
        # Core library
        "lib",
        "priv/proto",
        "priv/python/*.py",
        "priv/python/requirements*.txt",
        "priv/python/setup.py",
        "priv/python/snakepit_bridge/**/*.py",
        "priv/python/snakepit_bridge/**/py.typed",
        "priv/python/README_THREADING.md",
        # Build configuration
        ".formatter.exs",
        "mix.exs",
        # Root documentation
        "README.md",
        "CHANGELOG.md",
        "LICENSE*"
      ],
      exclude_patterns: [
        "**/__pycache__",
        "**/__pycache__/**",
        "**/*.pyc",
        "**/*.egg-info",
        "**/*.bak",
        "priv/plts",
        "priv/data",
        "docs/archive"
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

        # Guides
        {"guides/getting-started.md", title: "Getting Started"},
        {"guides/configuration.md", title: "Configuration"},
        {"guides/worker-profiles.md", title: "Worker Profiles"},
        {"guides/timeout-configuration-guide.md", title: "Timeout Configuration"},
        {"guides/session-scoping-rules.md", title: "Session Scoping"},
        {"guides/hardware-detection.md", title: "Hardware Detection"},
        {"guides/fault-tolerance.md", title: "Fault Tolerance"},
        {"guides/streaming.md", title: "Streaming"},
        {"guides/graceful-serialization.md", title: "Graceful Serialization"},
        {"guides/python-adapters.md", title: "Python Adapters"},
        {"guides/observability.md", title: "Observability"},
        {"guides/production.md", title: "Production"},

        # Python threading guide
        {"priv/python/README_THREADING.md", title: "Python Threading Guide"},

        # Release notes and license
        "CHANGELOG.md",
        "LICENSE"
      ],
      groups_for_extras: [
        Introduction: [
          "README.md",
          "guides/getting-started.md"
        ],
        Configuration: [
          "guides/configuration.md",
          "guides/worker-profiles.md",
          "guides/timeout-configuration-guide.md",
          "guides/session-scoping-rules.md"
        ],
        Features: [
          "guides/hardware-detection.md",
          "guides/fault-tolerance.md",
          "guides/streaming.md",
          "guides/graceful-serialization.md"
        ],
        Development: [
          "guides/python-adapters.md",
          "priv/python/README_THREADING.md",
          "guides/observability.md"
        ],
        Operations: [
          "guides/production.md"
        ],
        "Release Notes": [
          "CHANGELOG.md"
        ],
        License: [
          "LICENSE"
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
        Serialization: [
          Snakepit.Serialization
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
