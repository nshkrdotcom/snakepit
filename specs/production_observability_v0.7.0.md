# Snakepit v0.7.0: Production-Grade Observability

**Feature**: Production-Grade Observability System  
**Priority**: P0 (Critical)  
**Status**: Design Phase  
**Target Release**: Snakepit v0.7.0  
**Estimated Effort**: 1-2 weeks  
**Dependencies**: None (foundational feature)

---

## Executive Summary

**Problem**: Current telemetry implementation is insufficient for production debugging and monitoring. Operators cannot effectively debug live systems, predict failures, or understand performance characteristics.

**Solution**: Comprehensive observability system with structured telemetry, health endpoints, Prometheus integration, and production-ready logging that enables operators to monitor, debug, and optimize Snakepit deployments at scale.

**Impact**: 
- Enables production deployments with confidence
- Reduces MTTR (Mean Time To Recovery) from hours to minutes
- Provides proactive failure detection and capacity planning
- Industry-standard monitoring integration (Prometheus, Grafana, LiveDashboard)

---

## Current State Analysis

### What Exists (v0.6.0)
```elixir
# Limited telemetry events
:telemetry.execute([:snakepit, :worker, :recycled], measurements, metadata)
:telemetry.execute([:snakepit, :pool, :saturated], measurements, metadata)
```

### Critical Gaps
1. **No consumption infrastructure** - Events are emitted but not consumed
2. **Incomplete event taxonomy** - Missing critical operational events
3. **No health endpoints** - Cannot integrate with load balancers/orchestrators
4. **Poor error visibility** - Python exceptions are swallowed
5. **No performance metrics** - Cannot optimize or capacity plan
6. **No alerting foundation** - Cannot detect issues proactively

---

## Requirements

### Functional Requirements

#### FR1: Comprehensive Event Taxonomy
**Requirement**: Emit structured telemetry events for all critical system operations
**Acceptance Criteria**:
- Pool lifecycle events (startup, shutdown, saturation)
- Worker lifecycle events (start, stop, crash, recycle, health_check)
- Request execution events (start, stop, success, failure, duration)
- Session management events (create, expire, cleanup)
- Error events (Python exceptions, gRPC failures, timeouts)
- Performance events (queue depth, response times, throughput)

#### FR2: Health Check Endpoints
**Requirement**: HTTP endpoints for system health monitoring
**Acceptance Criteria**:
- `/health` - Basic liveness check (200 OK if system responsive)
- `/health/ready` - Readiness check (200 OK if ready to serve traffic)
- `/health/detailed` - Comprehensive health with pool statistics
- Configurable health check criteria (worker availability, error rates)
- Integration with Kubernetes liveness/readiness probes

#### FR3: Metrics Integration
**Requirement**: Native integration with Prometheus and other metrics systems
**Acceptance Criteria**:
- Prometheus metrics endpoint (`/metrics`)
- Counter, gauge, histogram, and summary metrics
- Automatic metric registration and updates
- Configurable metric labels and dimensions
- Integration with PromEx library

#### FR4: Structured Logging
**Requirement**: Production-ready structured logging with correlation
**Acceptance Criteria**:
- JSON-structured log output
- Correlation IDs across request lifecycle
- Configurable log levels per component
- Request/response logging with sanitization
- Error context preservation (Python tracebacks)

#### FR5: Real-time Monitoring Dashboard
**Requirement**: Built-in monitoring dashboard for development and debugging
**Acceptance Criteria**:
- Phoenix LiveView dashboard showing real-time metrics
- Pool status, worker health, request queues
- Historical performance charts
- Error rate monitoring and alerting
- Integration with existing LiveDashboard

### Non-Functional Requirements

#### NFR1: Performance Impact
- Telemetry overhead < 1% of request latency
- Metrics collection < 0.1% CPU overhead
- Configurable sampling rates for high-volume events

#### NFR2: Reliability
- Observability system failures must not impact core functionality
- Graceful degradation when monitoring systems unavailable
- Circuit breaker pattern for external metric systems

#### NFR3: Security
- No sensitive data in logs or metrics
- Configurable data sanitization
- Rate limiting on health endpoints

#### NFR4: Compatibility
- Zero breaking changes to existing API
- Backward compatible with existing telemetry consumers
- Optional activation (can be disabled for minimal overhead)

---

## Technical Design

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    Snakepit Core System                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐     │
│  │    Pool      │    │   Workers    │    │ SessionStore │     │
│  │              │    │              │    │              │     │
│  └──────┬───────┘    └──────┬───────┘    └──────┬───────┘     │
│         │                   │                   │             │
│         └───────────────────┼───────────────────┘             │
│                             │                                 │
│                             ▼                                 │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │           Snakepit.Observability.EventBus              │  │
│  │                                                         │  │
│  │  • Event Collection & Routing                          │  │
│  │  • Correlation ID Management                           │  │
│  │  • Sampling & Rate Limiting                            │  │
│  │  • Error Context Preservation                          │  │
│  └─────────────────────┬───────────────────────────────────┘  │
└─────────────────────────┼─────────────────────────────────────┘
                          │
┌─────────────────────────┼─────────────────────────────────────┐
│              Observability Consumers                          │
├─────────────────────────┼─────────────────────────────────────┤
│                         ▼                                     │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │   Metrics    │  │   Logging    │  │    Health    │       │
│  │              │  │              │  │              │       │
│  │ • Prometheus │  │ • Structured │  │ • HTTP Checks│       │
│  │ • PromEx     │  │ • JSON       │  │ • LiveView   │       │
│  │ • StatsD     │  │ • Correlation│  │ • Dashboard  │       │
│  └──────────────┘  └──────────────┘  └──────────────┘       │
│                                                               │
└───────────────────────────────────────────────────────────────┘
```

### Event Taxonomy

#### Pool Events
```elixir
# Pool lifecycle
[:snakepit, :pool, :started]
# Measurements: %{pool_size: integer(), startup_time_ms: integer()}
# Metadata: %{pool_name: atom(), adapter_module: atom(), config: map()}

[:snakepit, :pool, :stopped]
# Measurements: %{uptime_ms: integer(), total_requests: integer()}
# Metadata: %{pool_name: atom(), reason: atom()}

[:snakepit, :pool, :saturated]
# Measurements: %{queue_size: integer(), max_queue_size: integer()}
# Metadata: %{pool_name: atom(), available_workers: integer(), busy_workers: integer()}

[:snakepit, :pool, :capacity_warning]
# Measurements: %{utilization_percent: float(), queue_depth: integer()}
# Metadata: %{pool_name: atom(), threshold_percent: float()}
```

#### Worker Events
```elixir
# Worker lifecycle
[:snakepit, :worker, :started]
# Measurements: %{startup_time_ms: integer()}
# Metadata: %{worker_id: string(), pool_name: atom(), adapter_module: atom()}

[:snakepit, :worker, :stopped]
# Measurements: %{uptime_ms: integer(), requests_handled: integer()}
# Metadata: %{worker_id: string(), pool_name: atom(), reason: atom()}

[:snakepit, :worker, :crashed]
# Measurements: %{uptime_ms: integer(), requests_handled: integer()}
# Metadata: %{worker_id: string(), pool_name: atom(), error: string(), stacktrace: list()}

[:snakepit, :worker, :recycled]
# Measurements: %{uptime_ms: integer(), requests_handled: integer()}
# Metadata: %{worker_id: string(), pool_name: atom(), reason: atom(), memory_mb: integer()}

[:snakepit, :worker, :health_check]
# Measurements: %{response_time_ms: integer()}
# Metadata: %{worker_id: string(), pool_name: atom(), status: atom(), details: map()}
```

#### Request Events
```elixir
# Request execution
[:snakepit, :request, :started]
# Measurements: %{queue_time_ms: integer()}
# Metadata: %{request_id: string(), command: string(), pool_name: atom(), worker_id: string(), session_id: string()}

[:snakepit, :request, :completed]
# Measurements: %{duration_ms: integer(), queue_time_ms: integer()}
# Metadata: %{request_id: string(), command: string(), pool_name: atom(), worker_id: string(), success: boolean()}

[:snakepit, :request, :failed]
# Measurements: %{duration_ms: integer(), queue_time_ms: integer()}
# Metadata: %{request_id: string(), command: string(), error_type: string(), error_message: string(), python_traceback: string()}

[:snakepit, :request, :timeout]
# Measurements: %{timeout_ms: integer(), queue_time_ms: integer()}
# Metadata: %{request_id: string(), command: string(), pool_name: atom(), worker_id: string()}
```

#### Session Events
```elixir
# Session management
[:snakepit, :session, :created]
# Measurements: %{creation_time_ms: integer()}
# Metadata: %{session_id: string(), ttl_seconds: integer(), metadata: map()}

[:snakepit, :session, :expired]
# Measurements: %{lifetime_ms: integer(), requests_handled: integer()}
# Metadata: %{session_id: string(), reason: atom()}

[:snakepit, :session, :cleanup]
# Measurements: %{sessions_cleaned: integer(), cleanup_time_ms: integer()}
# Metadata: %{cleanup_reason: atom()}
```

### Implementation Modules

#### 1. Event Bus (Core)
```elixir
defmodule Snakepit.Observability.EventBus do
  @moduledoc """
  Central event collection and routing system.
  
  Handles:
  - Event emission with correlation IDs
  - Sampling and rate limiting
  - Error context preservation
  - Consumer registration and routing
  """
  
  use GenServer
  
  @doc """
  Emit a telemetry event with automatic correlation ID injection.
  """
  def emit(event_name, measurements, metadata \\ %{}) do
    enhanced_metadata = 
      metadata
      |> add_correlation_id()
      |> add_timestamp()
      |> sanitize_sensitive_data()
    
    :telemetry.execute(event_name, measurements, enhanced_metadata)
  end
  
  @doc """
  Register a consumer for specific event patterns.
  """
  def register_consumer(event_pattern, consumer_module) do
    GenServer.call(__MODULE__, {:register_consumer, event_pattern, consumer_module})
  end
  
  # Private functions for correlation, sanitization, etc.
end
```

#### 2. Metrics Consumer
```elixir
defmodule Snakepit.Observability.Metrics do
  @moduledoc """
  Prometheus metrics integration.
  
  Automatically converts telemetry events to Prometheus metrics:
  - Counters for event counts
  - Gauges for current state
  - Histograms for durations
  - Summaries for percentiles
  """
  
  use GenServer
  
  # Metric definitions
  @metrics [
    # Counters
    counter("snakepit_requests_total", 
      help: "Total number of requests processed",
      labels: [:pool_name, :command, :status]),
    
    counter("snakepit_workers_started_total",
      help: "Total number of workers started",
      labels: [:pool_name, :adapter_module]),
    
    counter("snakepit_workers_crashed_total",
      help: "Total number of worker crashes",
      labels: [:pool_name, :error_type]),
    
    # Gauges
    gauge("snakepit_pool_available_workers",
      help: "Number of available workers in pool",
      labels: [:pool_name]),
    
    gauge("snakepit_pool_queue_size",
      help: "Current request queue size",
      labels: [:pool_name]),
    
    gauge("snakepit_sessions_active",
      help: "Number of active sessions",
      labels: []),
    
    # Histograms
    histogram("snakepit_request_duration_seconds",
      help: "Request execution duration",
      labels: [:pool_name, :command],
      buckets: [0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0, 5.0, 10.0]),
    
    histogram("snakepit_worker_startup_duration_seconds",
      help: "Worker startup duration",
      labels: [:pool_name, :adapter_module],
      buckets: [0.1, 0.5, 1.0, 2.0, 5.0, 10.0, 30.0])
  ]
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def init(_opts) do
    # Register metrics
    Enum.each(@metrics, &Prometheus.register/1)
    
    # Attach to telemetry events
    events = [
      [:snakepit, :request, :completed],
      [:snakepit, :request, :failed],
      [:snakepit, :worker, :started],
      [:snakepit, :worker, :crashed],
      [:snakepit, :pool, :saturated]
    ]
    
    :telemetry.attach_many("snakepit-metrics", events, &handle_event/4, nil)
    
    {:ok, %{}}
  end
  
  def handle_event([:snakepit, :request, :completed], measurements, metadata, _config) do
    labels = [metadata.pool_name, metadata.command, "success"]
    Prometheus.Counter.inc("snakepit_requests_total", labels)
    
    duration_labels = [metadata.pool_name, metadata.command]
    Prometheus.Histogram.observe("snakepit_request_duration_seconds", 
                                duration_labels, 
                                measurements.duration_ms / 1000)
  end
  
  # Additional event handlers...
end
```

#### 3. Health Check System
```elixir
defmodule Snakepit.Observability.HealthCheck do
  @moduledoc """
  HTTP health check endpoints for load balancers and orchestrators.
  
  Provides:
  - Basic liveness check (/health)
  - Readiness check (/health/ready)
  - Detailed health with metrics (/health/detailed)
  """
  
  use Plug.Router
  
  plug :match
  plug :dispatch
  
  get "/health" do
    case basic_health_check() do
      :ok ->
        send_resp(conn, 200, Jason.encode!(%{status: "ok", timestamp: DateTime.utc_now()}))
      {:error, reason} ->
        send_resp(conn, 503, Jason.encode!(%{status: "error", reason: reason}))
    end
  end
  
  get "/health/ready" do
    case readiness_check() do
      :ok ->
        send_resp(conn, 200, Jason.encode!(%{status: "ready", timestamp: DateTime.utc_now()}))
      {:error, reason} ->
        send_resp(conn, 503, Jason.encode!(%{status: "not_ready", reason: reason}))
    end
  end
  
  get "/health/detailed" do
    health_data = %{
      status: "ok",
      timestamp: DateTime.utc_now(),
      pools: get_pool_health(),
      system: get_system_health(),
      metrics: get_key_metrics()
    }
    
    send_resp(conn, 200, Jason.encode!(health_data))
  end
  
  defp basic_health_check do
    # Check if core processes are alive
    if Process.whereis(Snakepit.Pool) do
      :ok
    else
      {:error, "pool_not_running"}
    end
  end
  
  defp readiness_check do
    with :ok <- basic_health_check(),
         {:ok, stats} <- Snakepit.get_stats(),
         true <- stats.available_workers > 0,
         true <- stats.error_rate < 0.1 do
      :ok
    else
      false -> {:error, "no_available_workers"}
      {:error, reason} -> {:error, reason}
    end
  end
  
  defp get_pool_health do
    # Collect health data from all pools
    case Snakepit.get_stats() do
      {:ok, stats} ->
        %{
          total_workers: stats.total_workers,
          available_workers: stats.available_workers,
          busy_workers: stats.busy_workers,
          queue_size: stats.queue_size,
          error_rate: stats.error_rate,
          avg_response_time_ms: stats.avg_response_time_ms
        }
      {:error, _} ->
        %{status: "unavailable"}
    end
  end
  
  defp get_system_health do
    %{
      memory_mb: :erlang.memory(:total) / 1024 / 1024,
      process_count: :erlang.system_info(:process_count),
      port_count: length(Port.list()),
      uptime_seconds: :erlang.statistics(:wall_clock) |> elem(0) / 1000
    }
  end
  
  defp get_key_metrics do
    # Return key performance indicators
    %{
      requests_per_second: get_recent_rps(),
      avg_queue_time_ms: get_avg_queue_time(),
      worker_crash_rate: get_crash_rate()
    }
  end
end
```

#### 4. Structured Logging
```elixir
defmodule Snakepit.Observability.Logger do
  @moduledoc """
  Structured logging with correlation IDs and context preservation.
  
  Features:
  - JSON-structured output
  - Automatic correlation ID injection
  - Request/response logging
  - Error context preservation
  - Configurable sanitization
  """
  
  require Logger
  
  @doc """
  Log a request start with correlation ID.
  """
  def log_request_start(request_id, command, args, metadata \\ %{}) do
    log_data = %{
      event: "request_start",
      request_id: request_id,
      command: command,
      args: sanitize_args(args),
      timestamp: DateTime.utc_now(),
      correlation_id: get_correlation_id()
    }
    |> Map.merge(metadata)
    
    Logger.info(Jason.encode!(log_data))
  end
  
  @doc """
  Log a request completion with timing and result.
  """
  def log_request_complete(request_id, result, duration_ms, metadata \\ %{}) do
    log_data = %{
      event: "request_complete",
      request_id: request_id,
      success: match?({:ok, _}, result),
      duration_ms: duration_ms,
      result: sanitize_result(result),
      timestamp: DateTime.utc_now(),
      correlation_id: get_correlation_id()
    }
    |> Map.merge(metadata)
    
    Logger.info(Jason.encode!(log_data))
  end
  
  @doc """
  Log an error with full context preservation.
  """
  def log_error(error, context \\ %{}) do
    log_data = %{
      event: "error",
      error_type: error_type(error),
      error_message: error_message(error),
      stacktrace: format_stacktrace(error),
      context: context,
      timestamp: DateTime.utc_now(),
      correlation_id: get_correlation_id()
    }
    
    Logger.error(Jason.encode!(log_data))
  end
  
  @doc """
  Log Python exception with traceback preservation.
  """
  def log_python_error(python_error, request_context \\ %{}) do
    log_data = %{
      event: "python_error",
      error_type: python_error["type"] || "UnknownError",
      error_message: python_error["message"] || "No message",
      python_traceback: python_error["traceback"],
      request_context: request_context,
      timestamp: DateTime.utc_now(),
      correlation_id: get_correlation_id()
    }
    
    Logger.error(Jason.encode!(log_data))
  end
  
  # Private helper functions for sanitization and formatting
  defp sanitize_args(args) do
    # Remove sensitive data like passwords, tokens, etc.
    args
    |> Map.drop(["password", "token", "secret", "key"])
    |> Enum.map(fn {k, v} -> {k, sanitize_value(v)} end)
    |> Map.new()
  end
  
  defp sanitize_value(value) when is_binary(value) and byte_size(value) > 1000 do
    # Truncate large strings
    String.slice(value, 0, 1000) <> "... [truncated]"
  end
  defp sanitize_value(value), do: value
end
```

#### 5. LiveView Dashboard
```elixir
defmodule Snakepit.Observability.LiveDashboard do
  @moduledoc """
  Real-time monitoring dashboard using Phoenix LiveView.
  
  Displays:
  - Pool status and worker health
  - Request queue and throughput
  - Error rates and recent errors
  - Performance metrics and trends
  """
  
  use Phoenix.LiveView
  
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to telemetry events for real-time updates
      :telemetry.attach_many("dashboard-#{self()}", 
        [
          [:snakepit, :request, :completed],
          [:snakepit, :worker, :crashed],
          [:snakepit, :pool, :saturated]
        ], 
        &handle_telemetry_event/4, 
        socket.assigns)
      
      # Schedule periodic updates
      :timer.send_interval(1000, self(), :update_metrics)
    end
    
    {:ok, assign(socket, 
      pools: get_pool_stats(),
      recent_errors: get_recent_errors(),
      metrics: get_dashboard_metrics(),
      last_updated: DateTime.utc_now()
    )}
  end
  
  def handle_info(:update_metrics, socket) do
    {:noreply, assign(socket,
      pools: get_pool_stats(),
      metrics: get_dashboard_metrics(),
      last_updated: DateTime.utc_now()
    )}
  end
  
  def handle_info({:telemetry_event, event_name, measurements, metadata}, socket) do
    # Handle real-time telemetry events
    case event_name do
      [:snakepit, :worker, :crashed] ->
        error = %{
          timestamp: DateTime.utc_now(),
          worker_id: metadata.worker_id,
          error: metadata.error,
          pool: metadata.pool_name
        }
        
        recent_errors = [error | socket.assigns.recent_errors] |> Enum.take(10)
        {:noreply, assign(socket, recent_errors: recent_errors)}
      
      _ ->
        {:noreply, socket}
    end
  end
  
  def render(assigns) do
    ~H"""
    <div class="dashboard">
      <h1>Snakepit Observability Dashboard</h1>
      
      <div class="metrics-grid">
        <!-- Pool Status Cards -->
        <%= for pool <- @pools do %>
          <div class={"pool-card pool-#{pool.status}"}>
            <h3><%= pool.name %></h3>
            <div class="metrics">
              <div class="metric">
                <span class="label">Workers</span>
                <span class="value"><%= pool.available %>/<%= pool.total %></span>
              </div>
              <div class="metric">
                <span class="label">Queue</span>
                <span class="value"><%= pool.queue_size %></span>
              </div>
              <div class="metric">
                <span class="label">RPS</span>
                <span class="value"><%= pool.requests_per_second %></span>
              </div>
            </div>
          </div>
        <% end %>
        
        <!-- System Metrics -->
        <div class="system-metrics">
          <h3>System Health</h3>
          <div class="metrics">
            <div class="metric">
              <span class="label">Memory</span>
              <span class="value"><%= @metrics.memory_mb %>MB</span>
            </div>
            <div class="metric">
              <span class="label">Processes</span>
              <span class="value"><%= @metrics.process_count %></span>
            </div>
            <div class="metric">
              <span class="label">Uptime</span>
              <span class="value"><%= format_uptime(@metrics.uptime_seconds) %></span>
            </div>
          </div>
        </div>
        
        <!-- Recent Errors -->
        <div class="recent-errors">
          <h3>Recent Errors</h3>
          <%= for error <- @recent_errors do %>
            <div class="error-item">
              <span class="timestamp"><%= format_timestamp(error.timestamp) %></span>
              <span class="worker"><%= error.worker_id %></span>
              <span class="message"><%= error.error %></span>
            </div>
          <% end %>
        </div>
      </div>
      
      <div class="last-updated">
        Last updated: <%= format_timestamp(@last_updated) %>
      </div>
    </div>
    """
  end
  
  # Helper functions for data formatting and retrieval
end
```

### Configuration

```elixir
# config/config.exs
config :snakepit, :observability,
  # Enable/disable observability features
  enabled: true,
  
  # Telemetry configuration
  telemetry: [
    # Sample high-volume events to reduce overhead
    sampling_rates: %{
      [:snakepit, :request, :completed] => 1.0,  # Sample all requests
      [:snakepit, :worker, :health_check] => 0.1  # Sample 10% of health checks
    },
    
    # Correlation ID configuration
    correlation_id: [
      header_name: "x-correlation-id",
      generate_if_missing: true
    ]
  ],
  
  # Metrics configuration
  metrics: [
    enabled: true,
    prometheus_endpoint: "/metrics",
    
    # Custom metric definitions
    custom_metrics: [
      # Add application-specific metrics
    ]
  ],
  
  # Health check configuration
  health_checks: [
    enabled: true,
    endpoint_prefix: "/health",
    
    # Health check criteria
    criteria: [
      min_available_workers: 1,
      max_error_rate: 0.1,
      max_queue_size: 1000,
      max_response_time_ms: 5000
    ]
  ],
  
  # Logging configuration
  logging: [
    structured: true,
    format: :json,
    
    # Data sanitization
    sanitization: [
      enabled: true,
      sensitive_keys: ["password", "token", "secret", "key", "auth"],
      max_string_length: 1000
    ]
  ],
  
  # Dashboard configuration
  dashboard: [
    enabled: true,
    update_interval_ms: 1000,
    max_recent_errors: 50
  ]
```

---

## Integration Examples

### Prometheus + Grafana Setup

```yaml
# docker-compose.yml
version: '3.8'
services:
  snakepit-app:
    build: .
    ports:
      - "4000:4000"
    environment:
      - SNAKEPIT_OBSERVABILITY_ENABLED=true
  
  prometheus:
    image: prom/prometheus
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--web.console.libraries=/etc/prometheus/console_libraries'
      - '--web.console.templates=/etc/prometheus/consoles'

  grafana:
    image: grafana/grafana
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
    volumes:
      - ./grafana/dashboards:/var/lib/grafana/dashboards
```

```yaml
# prometheus.yml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'snakepit'
    static_configs:
      - targets: ['snakepit-app:4000']
    metrics_path: '/metrics'
    scrape_interval: 5s
```

### Kubernetes Integration

```yaml
# k8s/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: snakepit
  labels:
    app: snakepit
spec:
  replicas: 3
  selector:
    matchLabels:
      app: snakepit
  template:
    metadata:
      labels:
        app: snakepit
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "4000"
        prometheus.io/path: "/metrics"
    spec:
      containers:
      - name: snakepit
        image: snakepit:latest
        ports:
        - containerPort: 4000
        livenessProbe:
          httpGet:
            path: /health
            port: 4000
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health/ready
            port: 4000
          initialDelaySeconds: 5
          periodSeconds: 5
        env:
        - name: SNAKEPIT_OBSERVABILITY_ENABLED
          value: "true"
```

### Application Integration

```elixir
# In your application
defmodule MyApp.Application do
  use Application
  
  def start(_type, _args) do
    children = [
      # Start observability system early
      {Snakepit.Observability.EventBus, []},
      {Snakepit.Observability.Metrics, []},
      {Snakepit.Observability.HealthCheck, []},
      
      # Your application children
      MyApp.Repo,
      MyAppWeb.Endpoint,
      
      # Start Snakepit
      {Snakepit.Application, []}
    ]
    
    # Setup custom telemetry handlers
    setup_custom_telemetry()
    
    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
  
  defp setup_custom_telemetry do
    # Custom business logic telemetry
    :telemetry.attach_many(
      "myapp-snakepit-integration",
      [
        [:snakepit, :request, :completed],
        [:snakepit, :worker, :crashed]
      ],
      &MyApp.TelemetryHandler.handle_event/4,
      nil
    )
  end
end

defmodule MyApp.TelemetryHandler do
  require Logger
  
  def handle_event([:snakepit, :request, :completed], measurements, metadata, _config) do
    # Custom business logic
    if measurements.duration_ms > 5000 do
      Logger.warn("Slow Snakepit request detected", 
        command: metadata.command,
        duration_ms: measurements.duration_ms,
        worker_id: metadata.worker_id
      )
      
      # Maybe trigger alert or scaling action
      MyApp.AlertManager.notify_slow_request(metadata, measurements)
    end
  end
  
  def handle_event([:snakepit, :worker, :crashed], _measurements, metadata, _config) do
    # Alert on worker crashes
    MyApp.AlertManager.notify_worker_crash(metadata)
  end
end
```

---

## Testing Strategy

### Unit Tests
```elixir
defmodule Snakepit.Observability.EventBusTest do
  use ExUnit.Case
  
  test "emits events with correlation IDs" do
    # Test event emission
    Snakepit.Observability.EventBus.emit(
      [:test, :event], 
      %{count: 1}, 
      %{test: true}
    )
    
    # Verify correlation ID was added
    assert_receive {:telemetry, [:test, :event], %{count: 1}, metadata}
    assert Map.has_key?(metadata, :correlation_id)
    assert Map.has_key?(metadata, :timestamp)
  end
  
  test "sanitizes sensitive data" do
    Snakepit.Observability.EventBus.emit(
      [:test, :event],
      %{},
      %{password: "secret123", user: "john"}
    )
    
    assert_receive {:telemetry, [:test, :event], _, metadata}
    refute Map.has_key?(metadata, :password)
    assert metadata.user == "john"
  end
end

defmodule Snakepit.Observability.HealthCheckTest do
  use ExUnit.Case
  use Plug.Test
  
  test "health endpoint returns 200 when system healthy" do
    conn = conn(:get, "/health")
    conn = Snakepit.Observability.HealthCheck.call(conn, [])
    
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["status"] == "ok"
  end
  
  test "readiness endpoint returns 503 when no workers available" do
    # Mock no available workers
    with_mock(Snakepit, [get_stats: fn -> {:ok, %{available_workers: 0}} end]) do
      conn = conn(:get, "/health/ready")
      conn = Snakepit.Observability.HealthCheck.call(conn, [])
      
      assert conn.status == 503
      assert Jason.decode!(conn.resp_body)["status"] == "not_ready"
    end
  end
end
```

### Integration Tests
```elixir
defmodule Snakepit.Observability.IntegrationTest do
  use ExUnit.Case
  
  test "end-to-end observability flow" do
    # Start observability system
    {:ok, _} = start_supervised(Snakepit.Observability.EventBus)
    {:ok, _} = start_supervised(Snakepit.Observability.Metrics)
    
    # Execute a request and verify telemetry
    {:ok, result} = Snakepit.execute("ping", %{})
    
    # Verify metrics were updated
    assert Prometheus.Counter.value("snakepit_requests_total", ["default", "ping", "success"]) > 0
    
    # Verify health endpoint reflects current state
    conn = conn(:get, "/health/detailed")
    conn = Snakepit.Observability.HealthCheck.call(conn, [])
    
    assert conn.status == 200
    health_data = Jason.decode!(conn.resp_body)
    assert health_data["pools"]["available_workers"] > 0
  end
end
```

---

## Migration Guide

### From v0.6.0 to v0.7.0

#### Automatic Migration (Zero Breaking Changes)
```elixir
# Existing code works unchanged
{:ok, result} = Snakepit.execute("command", %{args: "value"})

# Observability is automatically enabled with default configuration
# No code changes required
```

#### Optional Enhancements
```elixir
# Add custom telemetry handlers
:telemetry.attach_many(
  "my-app-snakepit",
  [[:snakepit, :request, :completed]],
  &MyApp.handle_snakepit_event/4,
  nil
)

# Configure health check criteria
config :snakepit, :observability,
  health_checks: [
    criteria: [
      min_available_workers: 2,  # Require at least 2 workers
      max_error_rate: 0.05       # Alert if error rate > 5%
    ]
  ]

# Enable structured logging
config :logger, :console,
  format: {Snakepit.Observability.Logger, :format},
  metadata: [:correlation_id, :request_id]
```

#### Prometheus Integration
```elixir
# Add to your supervision tree
children = [
  # Existing children...
  {Snakepit.Observability.Metrics, []}
]

# Add metrics endpoint to your router
defmodule MyAppWeb.Router do
  use MyAppWeb, :router
  
  # Add metrics endpoint
  get "/metrics", Snakepit.Observability.Metrics, :export
end
```

---

## Performance Impact Analysis

### Telemetry Overhead
- **Event emission**: ~0.1-0.5μs per event
- **Correlation ID generation**: ~1μs per request
- **JSON serialization**: ~10-50μs per log entry
- **Total overhead**: <1% of typical request latency

### Memory Usage
- **Event metadata**: ~100-500 bytes per event
- **Metrics storage**: ~1KB per metric per label combination
- **Log buffers**: Configurable, default 1MB
- **Total memory**: <10MB for typical deployment

### Network Impact
- **Metrics endpoint**: ~1-10KB per scrape (depends on metric count)
- **Health checks**: ~100-500 bytes per check
- **Log shipping**: Depends on log volume and destination

### Mitigation Strategies
```elixir
# Configure sampling for high-volume events
config :snakepit, :observability,
  telemetry: [
    sampling_rates: %{
      [:snakepit, :request, :completed] => 0.1,  # Sample 10% of requests
      [:snakepit, :worker, :health_check] => 0.01  # Sample 1% of health checks
    }
  ]

# Disable observability in development if needed
config :snakepit, :observability,
  enabled: Mix.env() == :prod

# Configure log levels
config :logger, level: :info  # Reduce debug noise in production
```

---

## Success Metrics

### Operational Metrics
- **MTTR Reduction**: From hours to minutes for common issues
- **Proactive Detection**: 90% of issues detected before user impact
- **Capacity Planning**: Accurate prediction of scaling needs
- **Error Visibility**: 100% of Python exceptions captured with context

### Adoption Metrics
- **Health Check Integration**: 100% of production deployments use health endpoints
- **Metrics Integration**: 80% of users integrate with Prometheus/Grafana
- **Dashboard Usage**: 50% of users utilize built-in LiveView dashboard
- **Custom Telemetry**: 30% of users add custom telemetry handlers

### Performance Metrics
- **Overhead**: <1% impact on request latency
- **Memory Usage**: <10MB additional memory usage
- **Reliability**: 99.9% observability system uptime
- **Accuracy**: 100% correlation between telemetry and actual system state

---

## Future Enhancements (Post-v0.7.0)

### v0.8.0 Candidates
- **Distributed Tracing**: OpenTelemetry integration for multi-service traces
- **Advanced Alerting**: Built-in alerting rules and notification channels
- **Performance Profiling**: Automatic performance bottleneck detection
- **Capacity Optimization**: ML-based capacity planning recommendations

### v0.9.0 Candidates
- **Custom Dashboards**: User-configurable dashboard widgets
- **Historical Analytics**: Long-term trend analysis and reporting
- **Anomaly Detection**: Statistical anomaly detection for metrics
- **Integration Marketplace**: Pre-built integrations for popular monitoring tools

---

## Conclusion

This Production-Grade Observability system transforms Snakepit from "impressive architecture" to "production-ready infrastructure" by providing:

1. **Complete Visibility**: Every important system event is captured and available for analysis
2. **Proactive Monitoring**: Health checks and metrics enable proactive issue detection
3. **Rapid Debugging**: Structured logging and correlation IDs enable fast problem resolution
4. **Industry Integration**: Native support for Prometheus, Grafana, and Kubernetes
5. **Zero Breaking Changes**: Existing code continues to work unchanged

The implementation provides a solid foundation for production deployments while maintaining Snakepit's core principles of performance and simplicity.