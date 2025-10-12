#!/usr/bin/env elixir
#
# Snakepit Example Runner - Interactive Demo Launcher
#
# A user-friendly helper to run Snakepit examples and demos.
# Provides organized access to all example scripts with descriptions.
#
# Usage:
#   mix run examples/run_examples.exs
#   mix run examples/run_examples.exs --category gil
#   mix run examples/run_examples.exs --run hybrid
#   mix run examples/run_examples.exs --list
#

defmodule ExampleRunner do
  @moduledoc """
  Interactive runner for Snakepit examples and demonstrations.

  Organizes examples by category and provides easy access to all demos.
  """

  @examples %{
    basics: %{
      name: "Basic Examples",
      description: "Fundamental Snakepit usage patterns",
      scripts: [
        %{
          id: "basic",
          name: "Basic gRPC Demo",
          file: "grpc_basic.exs",
          description: "Simple gRPC worker usage",
          duration: "< 1 minute"
        },
        %{
          id: "sessions",
          name: "Sessions Demo",
          file: "grpc_sessions.exs",
          description: "Session-based execution with worker affinity",
          duration: "< 1 minute"
        }
      ]
    },
    gil: %{
      name: "GIL & Threading (v0.6.0)",
      description: "Dual-mode parallelism and Python 3.13+ features",
      scripts: [
        %{
          id: "comparison",
          name: "Process vs Thread Comparison",
          file: "dual_mode/process_vs_thread_comparison.exs",
          description: "Side-by-side comparison of both profiles",
          duration: "< 1 minute",
          highlight: true
        },
        %{
          id: "hybrid",
          name: "Hybrid Pools",
          file: "dual_mode/hybrid_pools.exs",
          description: "Multiple pools with different profiles (RECOMMENDED PATTERN)",
          duration: "< 1 minute",
          highlight: true
        },
        %{
          id: "threaded",
          name: "Threaded Profile Demo",
          file: "threaded_profile_demo.exs",
          description: "Multi-threaded worker demonstration",
          duration: "< 1 minute"
        }
      ]
    },
    lifecycle: %{
      name: "Worker Lifecycle (v0.6.0)",
      description: "Automatic worker recycling and management",
      scripts: [
        %{
          id: "ttl",
          name: "TTL-Based Recycling",
          file: "lifecycle/ttl_recycling_demo.exs",
          description: "Time-based worker recycling (prevents memory leaks)",
          duration: "< 1 minute",
          highlight: true
        }
      ]
    },
    monitoring: %{
      name: "Monitoring & Observability (v0.6.0)",
      description: "Telemetry integration and diagnostics",
      scripts: [
        %{
          id: "telemetry",
          name: "Telemetry Integration",
          file: "monitoring/telemetry_integration.exs",
          description: "Telemetry events, Prometheus, LiveDashboard integration",
          duration: "< 1 minute",
          highlight: true
        }
      ]
    },
    advanced: %{
      name: "Advanced Usage",
      description: "Complex patterns and streaming",
      scripts: [
        %{
          id: "streaming",
          name: "Streaming Demo",
          file: "grpc_streaming.exs",
          description: "Server-side streaming with callbacks",
          duration: "1-2 minutes"
        },
        %{
          id: "concurrent",
          name: "Concurrent Execution",
          file: "grpc_concurrent.exs",
          description: "High-concurrency patterns",
          duration: "1-2 minutes"
        },
        %{
          id: "advanced",
          name: "Advanced Features",
          file: "grpc_advanced.exs",
          description: "Advanced gRPC and session features",
          duration: "2-3 minutes"
        }
      ]
    },
    tools: %{
      name: "Bidirectional Tools",
      description: "Elixir ↔ Python tool bridge",
      scripts: [
        %{
          id: "tools",
          name: "Bidirectional Tools Demo",
          file: "bidirectional_tools_demo.exs",
          description: "Call Elixir functions from Python adapters",
          duration: "1-2 minutes"
        },
        %{
          id: "tools_auto",
          name: "Bidirectional Tools (Auto)",
          file: "bidirectional_tools_demo_auto.exs",
          description: "Automatic tool registration",
          duration: "1-2 minutes"
        }
      ]
    },
    stress: %{
      name: "Performance & Stress Tests",
      description: "Test pool limits and performance",
      scripts: [
        %{
          id: "streaming_demo",
          name: "Streaming Performance",
          file: "grpc_streaming_demo.exs",
          description: "Streaming performance demonstration",
          duration: "2-3 minutes"
        }
      ]
    }
  }

  def main(args) do
    parse_args(args)
  end

  defp parse_args(args) do
    case args do
      [] ->
        show_interactive_menu()

      ["--category", category] ->
        run_category(category)

      ["--run", script_id] ->
        run_script_by_id(script_id)

      ["--list"] ->
        list_all_examples()

      ["--help"] ->
        show_help()

      _ ->
        IO.puts("Unknown option. Use --help for usage information.")
        show_help()
    end
  end

  defp show_interactive_menu do
    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("Snakepit Example Runner - Interactive Mode")
    IO.puts(String.duplicate("=", 70) <> "\n")

    IO.puts("Categories:\n")

    @examples
    |> Enum.sort_by(fn {_key, cat} -> category_order(cat.name) end)
    |> Enum.each(fn {key, category} ->
      count = length(category.scripts)
      IO.puts("  #{format_category_key(key)} - #{category.name} (#{count} examples)")
      IO.puts("     #{category.description}")
    end)

    IO.puts("\nQuick Start (v0.6.0 Features):")

    IO.puts(
      "  1. Process vs Thread comparison:  mix run examples/run_examples.exs --run comparison"
    )

    IO.puts("  2. Hybrid pools (recommended):    mix run examples/run_examples.exs --run hybrid")
    IO.puts("  3. Worker recycling:              mix run examples/run_examples.exs --run ttl")

    IO.puts(
      "  4. Telemetry integration:         mix run examples/run_examples.exs --run telemetry"
    )

    IO.puts("\nRun by category:")
    IO.puts("  mix run examples/run_examples.exs --category gil")
    IO.puts("  mix run examples/run_examples.exs --category basics")
    IO.puts("  mix run examples/run_examples.exs --category advanced")

    IO.puts("\nOther options:")
    IO.puts("  --list    List all available examples")
    IO.puts("  --help    Show detailed help")

    IO.puts("\n" <> String.duplicate("=", 70) <> "\n")
  end

  defp show_help do
    IO.puts("""

    Snakepit Example Runner - Help
    ===============================

    Run Snakepit examples and demonstrations easily.

    Usage:
      mix run examples/run_examples.exs [options]

    Options:
      (none)              Interactive mode - shows menu
      --list              List all available examples
      --category CAT      Run all examples in category
      --run ID            Run specific example by ID
      --help              Show this help

    Categories:
      basics      - Basic Snakepit usage
      gil         - v0.6.0 dual-mode parallelism (GIL removal)
      lifecycle   - Worker recycling and lifecycle
      monitoring  - Telemetry and diagnostics
      advanced    - Complex patterns and streaming
      tools       - Bidirectional tool bridge
      stress      - Performance and stress tests

    Example IDs:
      comparison  - Process vs Thread comparison (RECOMMENDED)
      hybrid      - Hybrid pools (RECOMMENDED)
      threaded    - Threaded profile demo
      ttl         - TTL-based recycling (RECOMMENDED)
      telemetry   - Telemetry integration (RECOMMENDED)
      basic       - Basic gRPC usage
      sessions    - Session management
      streaming   - Streaming demo
      concurrent  - Concurrent execution
      advanced    - Advanced features
      tools       - Bidirectional tools
      tools_auto  - Bidirectional tools (auto)

    Examples:
      # Interactive mode
      mix run examples/run_examples.exs

      # Run all GIL/threading examples
      mix run examples/run_examples.exs --category gil

      # Run specific example
      mix run examples/run_examples.exs --run comparison

      # List all
      mix run examples/run_examples.exs --list

    Recommended Starting Point:
      mix run examples/run_examples.exs --run comparison

    This shows the process vs thread profile comparison and explains
    when to use each mode.
    """)
  end

  defp list_all_examples do
    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("All Available Examples")
    IO.puts(String.duplicate("=", 70) <> "\n")

    @examples
    |> Enum.sort_by(fn {_key, cat} -> category_order(cat.name) end)
    |> Enum.each(fn {_key, category} ->
      IO.puts("#{category.name}")
      IO.puts("  #{category.description}")
      IO.puts("")

      category.scripts
      |> Enum.each(fn script ->
        highlight = if script[:highlight], do: " ⭐", else: ""
        IO.puts("  [#{script.id}] #{script.name}#{highlight}")
        IO.puts("      File: #{script.file}")
        IO.puts("      #{script.description}")
        IO.puts("      Duration: #{script.duration}")
        IO.puts("")
      end)
    end)

    IO.puts("⭐ = Recommended for v0.6.0 users")
    IO.puts("")
  end

  defp run_category(category_key) do
    category_atom = String.to_existing_atom(category_key)

    case Map.get(@examples, category_atom) do
      nil ->
        IO.puts("Unknown category: #{category_key}")
        IO.puts("Available: #{Map.keys(@examples) |> Enum.join(", ")}")

      category ->
        IO.puts("\n" <> String.duplicate("=", 70))
        IO.puts("Running: #{category.name}")
        IO.puts(String.duplicate("=", 70) <> "\n")

        category.scripts
        |> Enum.each(fn script ->
          run_script(script)
          IO.puts("\n" <> String.duplicate("-", 70) <> "\n")
        end)

        IO.puts("Category complete: #{category.name}\n")
    end
  rescue
    ArgumentError ->
      IO.puts("Unknown category: #{category_key}")
      IO.puts("Available categories: #{Map.keys(@examples) |> Enum.join(", ")}")
  end

  defp run_script_by_id(script_id) do
    case find_script_by_id(script_id) do
      nil ->
        IO.puts("Unknown example ID: #{script_id}")
        IO.puts("\nAvailable IDs:")

        @examples
        |> Enum.flat_map(fn {_k, cat} -> cat.scripts end)
        |> Enum.each(fn script ->
          IO.puts("  #{script.id} - #{script.name}")
        end)

      {script, _category} ->
        run_script(script)
    end
  end

  defp run_script(script) do
    file_path = Path.join("examples", script.file)

    IO.puts("Running: #{script.name}")
    IO.puts("File: #{script.file}")
    IO.puts("Description: #{script.description}")
    IO.puts("")

    if File.exists?(file_path) do
      # Run the script
      case System.cmd("mix", ["run", file_path], stderr_to_stdout: true) do
        {output, 0} ->
          IO.puts(output)

        {output, exit_code} ->
          IO.puts(output)
          IO.puts("\n⚠️  Script exited with code #{exit_code}")
      end
    else
      IO.puts("⚠️  File not found: #{file_path}")
      IO.puts("This example may not be implemented yet.")
    end
  end

  defp find_script_by_id(script_id) do
    @examples
    |> Enum.flat_map(fn {cat_key, category} ->
      Enum.map(category.scripts, fn script -> {script, cat_key} end)
    end)
    |> Enum.find(fn {script, _cat} -> script.id == script_id end)
  end

  defp format_category_key(key) do
    key
    |> Atom.to_string()
    |> String.pad_trailing(12)
  end

  defp category_order(name) do
    # Sort order for categories
    case name do
      "Basic Examples" -> 1
      "GIL & Threading (v0.6.0)" -> 2
      "Worker Lifecycle (v0.6.0)" -> 3
      "Monitoring & Observability (v0.6.0)" -> 4
      "Advanced Usage" -> 5
      "Bidirectional Tools" -> 6
      "Performance & Stress Tests" -> 7
      _ -> 99
    end
  end
end

# Run the example runner
ExampleRunner.main(System.argv())
