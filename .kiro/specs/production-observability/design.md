# Production-Grade Observability - Design Document

## Overview

The Production-Grade Observability system provides comprehensive monitoring, logging, and health checking capabilities for Snakepit. The design follows a modular architecture with pluggable consumers and minimal performance impact on core functionality.

## Architecture

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Snakepit Core System                         │
├─────────────────────────────────────────────────────────────────┤
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐     │
│  │    Pool      │    │   Workers    │    │ SessionStore │     │
│  │              │    │              │    │              │     │
│  └──────┬───────┘    └──────┬───────┘    └──────┬───────┘     │
│         │                   │                   │             │
│         └───────────────────┼───────────────────┘             │
│                             │                                 │
│                             ▼                                 │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │           Observability.EventBus                       │  │
│  │  • Event Collection & Routing                          │  │
│  │  • Correlation ID Management                           │  │
│  │  • Sampling & Rate Limiting                            │  │
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
│  │ • Counters   │  │ • JSON       │  │ • LiveView   │       │
│  │ • Histograms │  │ • Correlation│  │ • Dashboard  │       │
│  └──────────────┘  └──────────────┘  └──────────────┘       │
└───────────────────────────────────────────────────────────────┘
```

### Core Components

#### 1. EventBus (Central Coordination)
- **Purpose**: Central event collection and routing system
- **Responsibilities**:
  - Event emission with automatic correlation ID injection
  - Sampling and rate limiting for high-volume events
  - Data sanitization and security
  - Consumer registration and event routing
- **Implementation**: GenServer with registered consumers

#### 2. Metrics Consumer
- **Purpose**: Prometheus metrics integration
- **Responsibilities**:
  - Convert telemetry events to Prometheus metrics
  - Maintain counters, gauges, histograms, and summaries
  - Provide /metrics endpoint for scraping
  - Handle metric registration and updates
- **Implementation**: GenServer with Prometheus library integration

#### 3. Health Check System
- **Purpose**: HTTP health endpoints for orchestration
- **Responsibilities**:
  - Basic liveness checks (/health)
  - Readiness checks (/health/ready)
  - Detailed health reporting (/health/detailed)
  - Configurable health criteria
- **Implementation**: Plug router with health check logic

#### 4. Structured Logger
- **Purpose**: Production-ready logging with correlation
- **Responsibilities**:
  - JSON-structured log output
  - Correlation ID management
  - Data sanitization
  - Error context preservation
- **Implementation**: Logger backend with custom formatters##
 Components and Interfaces

### EventBus Interface

```elixir
defmodule Snakepit.Observability.EventBus do
  @callback emit(event_name :: list(atom()), measurements :: map(), metadata :: map()) :: :ok
  @callback register_consumer(event_pattern :: list(atom()), consumer_module :: atom()) :: :ok
  @callback set_sampling_rate(event_name :: list(atom()), rate :: float()) :: :ok
end
```

### Metrics Interface

```elixir
defmodule Snakepit.Observability.Metrics do
  @callback register_metric(metric_spec :: map()) :: :ok
  @callback update_counter(name :: atom(), labels :: map(), value :: number()) :: :ok
  @callback update_gauge(name :: atom(), labels :: map(), value :: number()) :: :ok
  @callback observe_histogram(name :: atom(), labels :: map(), value :: number()) :: :ok
end
```

### Health Check Interface

```elixir
defmodule Snakepit.Observability.HealthCheck do
  @callback check_health() :: :ok | {:error, term()}
  @callback check_readiness() :: :ok | {:error, term()}
  @callback get_detailed_health() :: map()
end
```

## Data Models

### Event Structure

```elixir
%{
  event_name: [:snakepit, :request, :completed],
  measurements: %{
    duration_ms: 150,
    queue_time_ms: 25
  },
  metadata: %{
    request_id: "req_123",
    correlation_id: "corr_456",
    command: "inference",
    pool_name: :default,
    worker_id: "worker_1",
    success: true,
    timestamp: ~U[2025-01-15 10:30:00Z]
  }
}
```

### Metric Definitions

```elixir
@metrics [
  # Counters
  %{
    type: :counter,
    name: :snakepit_requests_total,
    help: "Total number of requests processed",
    labels: [:pool_name, :command, :status]
  },
  
  # Gauges
  %{
    type: :gauge,
    name: :snakepit_pool_available_workers,
    help: "Number of available workers in pool",
    labels: [:pool_name]
  },
  
  # Histograms
  %{
    type: :histogram,
    name: :snakepit_request_duration_seconds,
    help: "Request execution duration",
    labels: [:pool_name, :command],
    buckets: [0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0, 5.0, 10.0]
  }
]
```

### Health Check Response

```elixir
%{
  status: "ok" | "warning" | "error",
  timestamp: ~U[2025-01-15 10:30:00Z],
  pools: %{
    default: %{
      total_workers: 10,
      available_workers: 8,
      busy_workers: 2,
      queue_size: 0,
      error_rate: 0.02,
      avg_response_time_ms: 145
    }
  },
  system: %{
    memory_mb: 256.5,
    process_count: 1024,
    port_count: 45,
    uptime_seconds: 86400
  },
  checks: [
    %{name: "worker_availability", status: "ok", message: "8/10 workers available"},
    %{name: "error_rate", status: "ok", message: "Error rate 2% below threshold"},
    %{name: "queue_depth", status: "ok", message: "Queue empty"}
  ]
}
```

## Error Handling

### Error Classification

1. **System Errors**: BEAM process crashes, OOM conditions
2. **Worker Errors**: Python process crashes, gRPC failures
3. **Request Errors**: Command execution failures, timeouts
4. **Configuration Errors**: Invalid observability configuration

### Error Recovery Strategies

1. **Graceful Degradation**: Observability failures don't impact core functionality
2. **Circuit Breaker**: Disable failing observability components temporarily
3. **Retry Logic**: Automatic retry for transient failures
4. **Fallback Modes**: Simplified logging when structured logging fails

### Error Context Preservation

```elixir
%{
  error_type: "PythonException",
  error_message: "ValueError: Invalid input shape",
  python_traceback: "Traceback (most recent call last):\n  File...",
  request_context: %{
    request_id: "req_123",
    command: "inference",
    args: %{model: "bert", input: "[SANITIZED]"}
  },
  system_context: %{
    worker_id: "worker_1",
    pool_name: :default,
    memory_mb: 512.3,
    uptime_seconds: 3600
  },
  correlation_id: "corr_456",
  timestamp: ~U[2025-01-15 10:30:00Z]
}
```

## Testing Strategy

### Unit Testing Approach

1. **EventBus Testing**: Mock consumers, verify event routing and sampling
2. **Metrics Testing**: Verify metric updates and Prometheus format
3. **Health Check Testing**: Mock system state, verify response codes
4. **Logger Testing**: Verify JSON structure and sanitization

### Integration Testing Approach

1. **End-to-End Flow**: Execute requests, verify telemetry chain
2. **Performance Testing**: Measure observability overhead
3. **Failure Testing**: Inject failures, verify error handling
4. **Configuration Testing**: Test various configuration scenarios

### Test Data Management

1. **Sanitization Testing**: Verify sensitive data removal
2. **Correlation Testing**: Verify correlation ID propagation
3. **Sampling Testing**: Verify sampling rate compliance
4. **Load Testing**: Verify performance under high event volume