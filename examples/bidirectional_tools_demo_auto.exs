#!/usr/bin/env elixir

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

Application.put_env(:snakepit, :grpc_listener, %{mode: :internal})
Application.put_env(:snakepit, :pooling_enabled, false)

defmodule BidirectionalToolsDemoAuto do
  def run(auto_stop_ms) do
    {:ok, listener} = Snakepit.GRPC.Listener.start_link(name: nil)
    Process.unlink(listener)
    {:ok, info} = Snakepit.GRPC.Listener.await_ready(5_000)
    grpc_address = "#{info.host}:#{info.port}"

    try do
      session_id = "bidirectional-demo"
      SessionStore.delete_session(session_id)

      {:ok, _session} =
        SessionStore.create_session(
          session_id,
          metadata: %{"demo" => "bidirectional_tools"}
        )

      IO.puts("\n=== Bidirectional Tool Bridge Server ===")
      IO.puts("Session ID: #{session_id}")
      IO.puts("gRPC Server running on #{grpc_address}\n")

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

      elixir_tools = ToolRegistry.list_exposed_elixir_tools(session_id)
      IO.puts("Registered #{length(elixir_tools)} Elixir tools:")

      for tool <- elixir_tools do
        IO.puts("  - #{tool.name}: #{tool.description}")
      end

      IO.puts("\nServer is ready for Python connections!")
      IO.puts("Run the Python demo in another terminal:")

      IO.puts(
        "  SNAKEPIT_GRPC_ADDRESS=#{grpc_address} python examples/python_elixir_tools_demo.py"
      )

      IO.puts("\nPress Ctrl+C to stop the server.")
      IO.puts("Set SNAKEPIT_DEMO_DURATION_MS to auto-stop for scripted runs.")

      wait_for_exit(auto_stop_ms)
    rescue
      _ ->
        IO.puts("\nShutting down...")
    after
      SessionStore.delete_session("bidirectional-demo")
      ToolRegistry.cleanup_session("bidirectional-demo")
      stop_grpc_supervisor(listener)
      IO.puts("Cleanup complete.")
    end
  end

  defp stop_grpc_supervisor(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :shutdown, 5_000)
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp stop_grpc_supervisor(_), do: :ok

  defp wait_for_exit(nil) do
    receive do
      :stop -> :ok
    end
  end

  defp wait_for_exit(auto_stop_ms) when is_integer(auto_stop_ms) and auto_stop_ms > 0 do
    IO.puts("Auto-stop enabled: stopping in #{div(auto_stop_ms, 1000)}s")

    receive do
    after
      auto_stop_ms -> :ok
    end
  end
end

auto_stop_ms =
  case System.get_env("SNAKEPIT_DEMO_DURATION_MS") ||
         System.get_env("SNAKEPIT_EXAMPLE_DURATION_MS") do
    nil ->
      nil

    value ->
      case Integer.parse(value) do
        {int, ""} when int > 0 -> int
        _ -> nil
      end
  end

Snakepit.Examples.Bootstrap.run_example(
  fn -> BidirectionalToolsDemoAuto.run(auto_stop_ms) end,
  await_pool: false
)
