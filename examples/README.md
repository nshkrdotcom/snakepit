# Snakepit Examples

User-friendly collection of examples demonstrating Snakepit v0.6.0 features.

## Quick Start

```bash
# Interactive browser
mix run examples/run_examples.exs

# Run recommended example
mix run examples/run_examples.exs --run comparison
```

## Recommended Examples

1. **comparison** - Process vs Thread profiles
2. **hybrid** - Multiple pools (BEST PRACTICE)
3. **ttl** - Worker recycling
4. **telemetry** - Monitoring setup

## Categories

- `gil` - v0.6.0 dual-mode features
- `basics` - Fundamentals
- `lifecycle` - Worker management
- `monitoring` - Observability
- `advanced` - Complex patterns
- `tools` - Bidirectional bridge

## Usage

```bash
mix run examples/run_examples.exs --list          # List all
mix run examples/run_examples.exs --run ID        # Run specific
mix run examples/run_examples.exs --category gil  # Run category
```
