defmodule Snakepit.Adapters.GenericPythonV2 do
  @moduledoc """
  Generic Python adapter for Snakepit V2.

  This adapter provides a robust, production-ready bridge to Python
  using the snakepit_bridge package structure. It includes:

  - Proper package imports instead of fragile sys.path manipulation
  - Support for both development and production deployments
  - Automatic fallback to development mode when package isn't installed
  - Enhanced error handling and graceful shutdown

  ## Supported Commands

  - `ping` - Health check and basic info
  - `echo` - Echo arguments back (useful for testing)
  - `compute` - Simple math operations (add, subtract, multiply, divide)
  - `info` - Bridge and system information

  ## Configuration

      config :snakepit,
        adapter_module: Snakepit.Adapters.GenericPythonV2

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

  ## Installation Modes

  This adapter supports two installation modes:

  1. **Package Mode** (Recommended for production):
     Install the bridge as a Python package:
     ```bash
     cd priv/python && pip install -e .
     ```
     Then the bridge can be invoked directly via console script.

  2. **Development Mode** (For development/testing):
     Uses the V2 bridge script with local package imports.
     No installation required - automatically detects package structure.
  """

  @behaviour Snakepit.Adapter

  @impl true
  def executable_path do
    System.find_executable("python3") || System.find_executable("python")
  end

  @impl true
  def script_path do
    # First check if we can import the package directly
    case check_python_package_available() do
      true ->
        # Package is available, try console script
        case System.find_executable("snakepit-generic-bridge") do
          nil ->
            # Package available but console script not found, use development script
            script_path_development()

          executable_path ->
            # Verify it's not a shell shim by checking if it contains Python code
            case File.read(executable_path) do
              {:ok, content} ->
                if String.contains?(content, "python") and
                     not String.contains?(content, "#!/bin/bash") do
                  executable_path
                else
                  # It's a shell shim, fall back to development mode
                  script_path_development()
                end

              {:error, _} ->
                # Can't read file, fall back to development mode
                script_path_development()
            end
        end

      false ->
        # Package not available, use development mode
        script_path_development()
    end
  end

  defp script_path_development do
    # Try application priv_dir first, fallback to relative path for development
    case :code.priv_dir(:snakepit) do
      {:error, :bad_name} ->
        # Development mode - use relative path from current working directory
        Path.join([File.cwd!(), "priv", "python", "generic_bridge_v2.py"])

      priv_dir ->
        Path.join(priv_dir, "python/generic_bridge_v2.py")
    end
  end

  @impl true
  def script_args do
    # Always use development mode arguments since we'll use development scripts
    # when shell shims are detected
    ["--mode", "pool-worker"]
  end

  defp check_python_package_available do
    # Check if snakepit_bridge package can be imported
    python_executable = executable_path()

    case System.cmd(python_executable, ["-c", "import snakepit_bridge; print('available')"],
           stderr_to_stdout: true
         ) do
      {"available\n", 0} -> true
      _ -> false
    end
  rescue
    _ -> false
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

  @doc """
  Check if the snakepit-bridge package is installed.

  Returns true if the package is available and can be imported,
  false if fallback to development mode is required.
  """
  def package_installed? do
    check_python_package_available()
  end

  @doc """
  Get installation instructions for the bridge package.
  """
  def installation_instructions do
    """
    To install the Snakepit Bridge package for production use:

    1. Navigate to the Python bridge directory:
       cd priv/python

    2. Install the package:
       pip install -e .  # Development install
       # or
       pip install .     # Regular install

    3. Verify installation:
       snakepit-generic-bridge --help

    The package will then be available system-wide and can be used
    by the GenericPythonV2 adapter automatically.
    """
  end
end
