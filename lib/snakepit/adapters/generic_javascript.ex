defmodule Snakepit.Adapters.GenericJavaScript do
  @moduledoc """
  Generic JavaScript/Node.js adapter for Snakepit.

  This adapter provides a simple, framework-agnostic bridge to Node.js
  without any external dependencies. It's useful for:

  - Testing the Snakepit infrastructure with JavaScript
  - Simple computational tasks in Node.js
  - Web scraping or API calls using JavaScript
  - As a template for building JavaScript-based adapters

  ## Supported Commands

  - `ping` - Health check and basic info
  - `echo` - Echo arguments back (useful for testing)
  - `compute` - Simple math operations (add, subtract, multiply, divide)
  - `info` - Bridge and system information
  - `random` - Generate random numbers with various distributions

  ## Configuration

      config :snakepit,
        adapter_module: Snakepit.Adapters.GenericJavaScript

  ## Usage Examples

      # Health check
      {:ok, result} = Snakepit.execute("ping", %{test: true})
      
      # Echo test
      {:ok, result} = Snakepit.execute("echo", %{message: "hello"})
      
      # Simple computation
      {:ok, result} = Snakepit.execute("compute", %{
        operation: "add",
        a: 5, 
        b: 3
      })
      
      # Random number generation
      {:ok, result} = Snakepit.execute("random", %{
        type: "uniform",
        min: 1,
        max: 100
      })
      
      # Get bridge info
      {:ok, result} = Snakepit.execute("info", %{})
  """

  @behaviour Snakepit.Adapter

  @impl true
  def executable_path do
    System.find_executable("node")
  end

  @impl true
  def script_path do
    Path.join(:code.priv_dir(:snakepit), "javascript/generic_bridge.js")
  end

  @impl true
  def script_args do
    ["--mode", "pool-worker"]
  end

  @impl true
  def supported_commands do
    ["ping", "echo", "compute", "info", "random"]
  end

  @impl true
  def validate_command("ping", _args), do: :ok

  def validate_command("echo", _args), do: :ok

  def validate_command("compute", args) do
    operation = Map.get(args, "operation") || Map.get(args, :operation)
    a = Map.get(args, "a") || Map.get(args, :a)
    b = Map.get(args, "b") || Map.get(args, :b)

    cond do
      operation not in ["add", "subtract", "multiply", "divide", "power", "sqrt"] ->
        {:error, "operation must be one of: add, subtract, multiply, divide, power, sqrt"}

      not is_number(a) ->
        {:error, "parameter 'a' must be a number"}

      operation in ["add", "subtract", "multiply", "divide", "power"] and not is_number(b) ->
        {:error, "parameter 'b' must be a number for operation '#{operation}'"}

      operation == "divide" and b == 0 ->
        {:error, "division by zero is not allowed"}

      operation == "sqrt" and a < 0 ->
        {:error, "square root of negative number is not allowed"}

      true ->
        :ok
    end
  end

  def validate_command("random", args) do
    type = Map.get(args, "type") || Map.get(args, :type)

    case type do
      "uniform" ->
        min = Map.get(args, "min") || Map.get(args, :min)
        max = Map.get(args, "max") || Map.get(args, :max)

        cond do
          not is_number(min) -> {:error, "parameter 'min' must be a number"}
          not is_number(max) -> {:error, "parameter 'max' must be a number"}
          min >= max -> {:error, "min must be less than max"}
          true -> :ok
        end

      "normal" ->
        mean = Map.get(args, "mean") || Map.get(args, :mean, 0)
        std = Map.get(args, "std") || Map.get(args, :std, 1)

        cond do
          not is_number(mean) -> {:error, "parameter 'mean' must be a number"}
          not is_number(std) -> {:error, "parameter 'std' must be a number"}
          std <= 0 -> {:error, "standard deviation must be positive"}
          true -> :ok
        end

      "integer" ->
        min = Map.get(args, "min") || Map.get(args, :min)
        max = Map.get(args, "max") || Map.get(args, :max)

        cond do
          not is_integer(min) -> {:error, "parameter 'min' must be an integer"}
          not is_integer(max) -> {:error, "parameter 'max' must be an integer"}
          min >= max -> {:error, "min must be less than max"}
          true -> :ok
        end

      nil ->
        {:error, "missing required parameter 'type'"}

      _ ->
        {:error, "type must be one of: uniform, normal, integer"}
    end
  end

  def validate_command("info", _args), do: :ok

  def validate_command(command, _args) do
    {:error,
     "unsupported command '#{command}'. Supported: #{Enum.join(supported_commands(), ", ")}"}
  end

  @impl true
  def prepare_args(_command, args) do
    # Convert atom keys to string keys for JSON serialization
    stringify_keys(args)
  end

  @impl true
  def process_response("compute", response) do
    # For compute commands, we could add additional validation or transformation
    case response do
      %{"status" => "ok", "result" => _result} = resp ->
        {:ok, resp}

      %{"status" => "error", "error" => error} ->
        {:error, "computation failed: #{error}"}

      other ->
        {:ok, other}
    end
  end

  def process_response("random", response) do
    # For random commands, validate that we got a numeric result
    case response do
      %{"status" => "ok", "value" => value} = resp when is_number(value) ->
        {:ok, resp}

      %{"status" => "error", "error" => error} ->
        {:error, "random generation failed: #{error}"}

      other ->
        {:ok, other}
    end
  end

  def process_response(_command, response) do
    {:ok, response}
  end

  # Helper function to convert atom keys to strings recursively
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list) do
    Enum.map(list, &stringify_keys/1)
  end

  defp stringify_keys(value), do: value
end
