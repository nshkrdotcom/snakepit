defmodule SnakepitShowcase.RunShowcase do
  @moduledoc """
  A single, coherent entry point to run and validate all Snakepit showcase demos.
  This orchestrates the setup and execution of all demonstrations.
  """

  # Alias all the demo modules for clean execution
  alias SnakepitShowcase.Demos.{
    BasicDemo,
    SessionDemo,
    StreamingDemo,
    ConcurrentDemo,
    BinaryDemo,
    MLWorkflowDemo,
    ExecutionModesDemo,
    GrpcToolsDemo
  }

  @demos [
    {"Basic Operations", BasicDemo},
    {"Session Management", SessionDemo},
    {"Streaming Operations", StreamingDemo},
    {"Concurrent Processing", ConcurrentDemo},
    {"Binary Serialization", BinaryDemo},
    {"ML Workflows", MLWorkflowDemo},
    {"Execution Modes Guide", ExecutionModesDemo},
    {"gRPC Tools Bridge", GrpcToolsDemo}
  ]

  def run do
    # --- 1. System Setup ---
    # The Snakepit.run_as_script wrapper handles application startup and configuration.

    # --- 2. Run Demonstrations ---
    IO.puts("\n\n=== Running Snakepit Showcase ===\n")
    IO.puts("This will run a series of demonstrations showcasing the full")
    IO.puts("capabilities of the Snakepit gRPC bridge and process pooler.")
    IO.puts(String.duplicate("-", 50))

    Enum.each(@demos, fn {name, module} ->
      IO.puts("\n\n📋 Running Demo: #{name}")
      IO.puts(String.duplicate("=", 40))
      module.run()
      IO.puts("✅ Demo '#{name}' complete.")
      IO.puts(String.duplicate("-", 50))
    end)

    IO.puts("\n\n✅✅✅ All Snakepit showcases completed successfully! ✅✅✅")
  end
end
