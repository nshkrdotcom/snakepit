# Snakepit Load Testing Suite

A comprehensive load testing framework for Snakepit Python integration, designed to stress test and benchmark the Python process pool under various load conditions.

## Features

- **Multiple load testing scenarios**: Basic, stress, burst, and sustained load patterns
- **Configurable worker counts**: Specify the number of concurrent workers via command line
- **Real-time metrics**: Track success rates, latencies, and throughput
- **Detailed analysis**: Performance degradation, stability metrics, and resource usage

## Installation

```bash
cd snakepit_loadtest
mix deps.get
```

## Usage

### Basic Load Test
Tests simple concurrent execution with configurable workers:

```bash
# Default: 10 workers
mix demo.basic

# Custom: 200 workers
mix demo.basic 200
```

### Stress Test
Pushes the system to its limits with memory-intensive and CPU-intensive workloads:

```bash
# Default: 50 workers
mix demo.stress

# Custom: 150 workers
mix demo.stress 150
```

### Burst Load Test
Simulates sudden traffic spikes with ramp-up and cool-down phases:

```bash
# Default: 100 peak workers
mix demo.burst

# Custom: 500 peak workers
mix demo.burst 500
```

### Sustained Load Test
Runs continuous load for 2 minutes to test long-term stability:

```bash
# Default: 20 workers
mix demo.sustained

# Custom: 50 workers
mix demo.sustained 50
```

## Test Scenarios

### 1. Basic Load Test (`demo.basic`)
- Simple compute tasks
- Configurable pool size (capped at 50)
- Measures basic throughput and latency

### 2. Stress Test (`demo.stress`)
- Three phases: Memory pressure, CPU intensive, Mixed workload
- Tests system limits and degradation patterns
- Identifies bottlenecks and failure modes

### 3. Burst Load Test (`demo.burst`)
- Simulates realistic traffic patterns
- 9 phases from warm-up to cool-down
- Tests burst handling and recovery characteristics

### 4. Sustained Load Test (`demo.sustained`)
- 2-minute continuous load
- Mixed workload (compute, memory, I/O)
- Monitors performance stability over time

## Metrics Collected

- **Success Rate**: Percentage of successful requests
- **Latency Statistics**: Min, Max, Mean, Median, P95, P99
- **Throughput**: Requests per second
- **Error Analysis**: Types and frequencies of failures
- **Performance Trends**: Degradation or improvement over time

## Configuration

The load tests automatically configure Snakepit's pool settings based on the worker count:

- Pool size is optimized per test type
- Max overflow allows handling of burst traffic
- Strategy (FIFO/LIFO) is chosen based on load pattern

## Example Output

```
🚀 Basic Load Test Demo
=======================
Workers: 100
Workload: Simple compute tasks

Warming up pool...
Starting load test...

📊 Results Summary
==================
Total workers: 100
Successful: 98 (98%)
Errors: 0
Timeouts: 2
Total time: 3245ms
Throughput: 30.20 req/s

⏱️  Response Time Statistics
============================
Min: 245.00ms
Max: 3201.00ms
Mean: 1623.45ms
Median: 1598.00ms
P95: 3045.00ms
P99: 3189.00ms
```

## Notes

- Worker counts are suggestions; actual concurrency depends on pool configuration
- Large worker counts (>200) may require system tuning
- Monitor system resources during stress tests
- Results vary based on hardware and system load