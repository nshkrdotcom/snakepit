defmodule Snakepit.Adapter do
  @moduledoc """
  Behaviour for implementing adapters in Snakepit.

  Adapters define how to communicate with external processes (Python, Node.js, etc.).
  This allows Snakepit to be truly generalized and support multiple ML frameworks
  or external systems.

  ## Required Callbacks

  - `executable_path/0` - Returns the path to the runtime executable (python3, node, etc.)
  - `script_path/0` - Returns the path to the external script to execute
  - `script_args/0` - Returns additional arguments for the script

  ## Example Implementation

      defmodule MyApp.PythonMLAdapter do
        @behaviour Snakepit.Adapter

        def executable_path, do: System.find_executable("python3") || System.find_executable("python")
        def script_path, do: Path.join(:code.priv_dir(:my_app), "python/ml_bridge.py")
        def script_args, do: ["--mode", "pool-worker"]
      end
  """

  @doc """
  Returns the path to the runtime executable.

  This is the interpreter or runtime that will execute the script.
  Examples: "python3", "node", "ruby", "R", etc.
  """
  @callback executable_path() :: String.t()

  @doc """
  Returns the path to the external script that will be executed.

  This should be an absolute path to a script that implements the
  bridge protocol for communication with Snakepit.
  """
  @callback script_path() :: String.t()

  @doc """
  Returns additional command-line arguments for the script.

  These arguments will be passed to the script when it's started.
  Common examples: ["--mode", "pool-worker"], ["--config", "prod"]
  """
  @callback script_args() :: [String.t()]

  @doc """
  Optional callback to get a command-specific timeout in milliseconds.

  This allows adapters to specify appropriate timeouts for different
  commands based on their expected execution time.
  """
  @callback command_timeout(command :: String.t(), args :: map()) :: pos_integer()

  @optional_callbacks [command_timeout: 2]
end
