#!/usr/bin/env elixir

# Bidirectional Tool Bridge Demonstration
#
# This example showcases the bidirectional tool execution between Elixir and Python:
# 1. Elixir tools exposed to Python
# 2. Python tools callable from Elixir  
# 3. Tool discovery and registration
# 4. Seamless cross-language execution

# Start by defining some Elixir tools
defmodule ElixirTools do
  @moduledoc """
  Example Elixir tools that can be called from Python.
  """

  def parse_json(params) do
    json_string = Map.get(params, "json_string", "{}")

    case Jason.decode(json_string) do
      {:ok, parsed} ->
        %{
          success: true,
          data: parsed,
          keys: Map.keys(parsed),
          size: map_size(parsed)
        }

      {:error, reason} ->
        %{
          success: false,
          error: "Failed to parse JSON: #{inspect(reason)}"
        }
    end
  end

  def calculate_fibonacci(params) do
    n = Map.get(params, "n", 10)

    result = fibonacci_sequence(n)

    %{
      n: n,
      sequence: result,
      sum: Enum.sum(result)
    }
  end

  defp fibonacci_sequence(n) when n <= 0, do: []
  defp fibonacci_sequence(1), do: [0]
  defp fibonacci_sequence(2), do: [0, 1]

  defp fibonacci_sequence(n) do
    Enum.reduce(3..n, [1, 0], fn _, [prev1, prev2 | _] = acc ->
      [prev1 + prev2 | acc]
    end)
    |> Enum.reverse()
  end

  def process_list(params) do
    list = Map.get(params, "list", [])
    operation = Map.get(params, "operation", "sum")

    result =
      case operation do
        "sum" -> Enum.sum(list)
        "max" -> Enum.max(list, fn -> nil end)
        "min" -> Enum.min(list, fn -> nil end)
        "mean" -> if list == [], do: nil, else: Enum.sum(list) / length(list)
        "reverse" -> Enum.reverse(list)
        _ -> {:error, "Unknown operation: #{operation}"}
      end

    %{
      list: list,
      operation: operation,
      result: result
    }
  end
end

# Main demonstration script
Code.require_file("mix_bootstrap.exs", __DIR__)

Snakepit.Examples.Bootstrap.ensure_mix!([
  {:snakepit, path: ".", override: true},
  {:jason, "~> 1.4"}
])

alias Snakepit.Bridge.{SessionStore, ToolRegistry}

# Configure the application
Application.put_env(:snakepit, :grpc_port, 50051)
Application.put_env(:snakepit, :pooling_enabled, false)

# Start the application with gRPC server
{:ok, _} = Application.ensure_all_started(:grpc)
{:ok, _} = Application.ensure_all_started(:snakepit)

# Start the gRPC server supervisor
{:ok, _} =
  Supervisor.start_link(
    [
      {GRPC.Server.Supervisor, endpoint: Snakepit.GRPC.Endpoint, port: 50051, start_server: true}
    ],
    strategy: :one_for_one
  )

# Wait for services to start
Process.sleep(500)

# Create a session
session_id = "bidirectional-demo-#{:os.system_time(:millisecond)}"

{:ok, _session} =
  SessionStore.create_session(session_id, metadata: %{"demo" => "bidirectional_tools"})

IO.puts("\n=== Bidirectional Tool Bridge Demo ===")
IO.puts("Session ID: #{session_id}\n")

# Register Elixir tools that Python can call
IO.puts("1. Registering Elixir tools...")

ToolRegistry.register_elixir_tool(
  session_id,
  "parse_json",
  &ElixirTools.parse_json/1,
  %{
    description: "Parse a JSON string and return analysis",
    exposed_to_python: true,
    parameters: [
      %{name: "json_string", type: "string", required: true}
    ]
  }
)

ToolRegistry.register_elixir_tool(
  session_id,
  "calculate_fibonacci",
  &ElixirTools.calculate_fibonacci/1,
  %{
    description: "Calculate Fibonacci sequence up to n numbers",
    exposed_to_python: true,
    parameters: [
      %{name: "n", type: "integer", required: true}
    ]
  }
)

ToolRegistry.register_elixir_tool(
  session_id,
  "process_list",
  &ElixirTools.process_list/1,
  %{
    description: "Process a list with various operations",
    exposed_to_python: true,
    parameters: [
      %{name: "list", type: "array", required: true},
      %{name: "operation", type: "string", required: false}
    ]
  }
)

# List registered Elixir tools
elixir_tools = ToolRegistry.list_exposed_elixir_tools(session_id)
IO.puts("Registered #{length(elixir_tools)} Elixir tools:")

for tool <- elixir_tools do
  IO.puts("  - #{tool.name}: #{tool.description}")
end

IO.puts("\n2. Testing direct Elixir tool execution...")

# Test direct execution
{:ok, result} =
  ToolRegistry.execute_local_tool(
    session_id,
    "parse_json",
    %{"json_string" => ~s({"name": "test", "value": 42})}
  )

IO.puts("Direct execution result: #{inspect(result)}")

IO.puts("\n3. Python Integration Demo")
IO.puts("Now Python can discover and call these Elixir tools!")
IO.puts("\nTo test from Python:")

IO.puts(~S"""
# In Python with a SessionContext:
ctx = SessionContext(stub, "#{session_id}")

# List available Elixir tools
print("Available Elixir tools:", list(ctx.elixir_tools.keys()))

# Call an Elixir tool
result = ctx.call_elixir_tool("calculate_fibonacci", n=10)
print("Fibonacci result:", result)

# Or use the proxy directly
parse_json = ctx.elixir_tools["parse_json"]
result = parse_json(json_string='{"test": true}')
print("Parse result:", result)
""")

IO.puts("\n4. Bidirectional Example")
IO.puts("Python tools registered in this session:")

# In a real scenario, Python would register its tools here
# For demo purposes, we'll simulate what Python tools might look like
python_tools = [
  %{name: "ml_analyze_text", type: :remote, description: "Analyze text using ML"},
  %{name: "process_image", type: :remote, description: "Process images with various filters"},
  %{name: "data_transform", type: :remote, description: "Transform data between formats"}
]

for tool <- python_tools do
  IO.puts("  - #{tool.name}: #{tool.description}")
end

IO.puts("\n5. Complete Workflow Example")

IO.puts(~S"""
A complete bidirectional workflow might look like:

1. Python receives data and does initial ML processing
2. Python calls Elixir's parse_json to validate structure  
3. Elixir processes the parsed data with business logic
4. Elixir calls Python's ml_analyze_text for sentiment
5. Results are combined and stored in Elixir

This seamless integration allows each language to handle
what it does best!
""")

IO.puts("\n=== Demo Complete ===")
IO.puts("Session #{session_id} contains both Elixir and Python tools")
IO.puts("Tools can be called bidirectionally through the gRPC bridge")

# Keep the server running for Python demo
IO.puts("\nPress Enter to stop the server and cleanup...")
IO.gets("")

# Cleanup
SessionStore.delete_session(session_id)
ToolRegistry.cleanup_session(session_id)
IO.puts("Server stopped and session cleaned up.")
