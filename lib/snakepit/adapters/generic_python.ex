defmodule Snakepit.Adapters.GenericPython do
  @moduledoc """
  Generic Python adapter for Snakepit.

  This adapter provides a simple, framework-agnostic bridge to Python
  without any external ML dependencies. It's useful for:

  - Testing the Snakepit infrastructure
  - Simple computational tasks
  - As a template for building your own adapters

  ## Supported Commands

  - `ping` - Health check and basic info
  - `echo` - Echo arguments back (useful for testing)
  - `compute` - Simple math operations (add, subtract, multiply, divide)
  - `info` - Bridge and system information

  ## Configuration

      config :snakepit,
        adapter_module: Snakepit.Adapters.GenericPython

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
      
      # Get bridge info
      {:ok, result} = Snakepit.execute("info", %{})
  """

  @behaviour Snakepit.Adapter

  @impl true
  def executable_path do
    System.find_executable("python3") || System.find_executable("python")
  end

  @impl true
  def script_path do
    # Try application priv_dir first, fallback to relative path for development
    case :code.priv_dir(:snakepit) do
      {:error, :bad_name} ->
        # Development mode - use relative path from current working directory
        Path.join([File.cwd!(), "priv", "python", "generic_bridge.py"])

      priv_dir ->
        Path.join(priv_dir, "python/generic_bridge.py")
    end
  end

  @impl true
  def script_args do
    ["--mode", "pool-worker"]
  end

  @impl true
  def supported_commands do
    ["ping", "echo", "compute", "info"]
  end

  @impl true
  def validate_command("ping", _args), do: :ok

  def validate_command("echo", _args), do: :ok

  def validate_command("compute", args) do
    operation = Map.get(args, "operation") || Map.get(args, :operation)
    a = Map.get(args, "a") || Map.get(args, :a)
    b = Map.get(args, "b") || Map.get(args, :b)

    cond do
      operation not in ["add", "subtract", "multiply", "divide"] ->
        {:error, "operation must be one of: add, subtract, multiply, divide"}

      not is_number(a) ->
        {:error, "parameter 'a' must be a number"}

      not is_number(b) ->
        {:error, "parameter 'b' must be a number"}

      operation == "divide" and b == 0 ->
        {:error, "division by zero is not allowed"}

      true ->
        :ok
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
    Snakepit.Utils.stringify_keys(args)
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

  def process_response(_command, response) do
    {:ok, response}
  end
end
