# Bidirectional Tool Bridge Demonstration (Auto-run version)
#
# This version runs without requiring manual interaction,
# suitable for running alongside the Python demo.

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
    
    result = case operation do
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
Mix.install([
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
{:ok, _} = Supervisor.start_link([
  {GRPC.Server.Supervisor, endpoint: Snakepit.GRPC.Endpoint, port: 50051, start_server: true}
], strategy: :one_for_one)

# Wait for services to start
Process.sleep(500)

# Use a fixed session ID for easy Python integration
session_id = "bidirectional-demo"
# Clean up any existing session first
SessionStore.delete_session(session_id)
{:ok, _session} = SessionStore.create_session(session_id, metadata: %{"demo" => "bidirectional_tools"})

IO.puts("\n=== Bidirectional Tool Bridge Server ===")
IO.puts("Session ID: #{session_id}")
IO.puts("gRPC Server running on port 50051\n")

# Register Elixir tools
IO.puts("Registering Elixir tools...")

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

# List registered tools
elixir_tools = ToolRegistry.list_exposed_elixir_tools(session_id)
IO.puts("Registered #{length(elixir_tools)} Elixir tools:")
for tool <- elixir_tools do
  IO.puts("  - #{tool.name}: #{tool.description}")
end

IO.puts("\nServer is ready for Python connections!")
IO.puts("Run the Python demo in another terminal:")
IO.puts("  python examples/python_elixir_tools_demo.py")
IO.puts("\nPress Ctrl+C to stop the server.")

# Keep the server running
try do
  Process.sleep(:infinity)
rescue
  _ ->
    IO.puts("\nShutting down...")
after
  # Always cleanup
  SessionStore.delete_session(session_id)
  ToolRegistry.cleanup_session(session_id)
  IO.puts("Cleanup complete.")
end