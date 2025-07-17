defmodule Snakepit.Adapter do
  @moduledoc """
  Behaviour for implementing adapters in Snakepit.

  Adapters define how to communicate with external processes (Python, Node.js, etc.)
  and what commands they support. This allows Snakepit to be truly generalized
  and support multiple ML frameworks or external systems.

  ## Required Callbacks

  - `executable_path/0` - Returns the path to the runtime executable (python3, node, etc.)
  - `script_path/0` - Returns the path to the external script to execute
  - `script_args/0` - Returns additional arguments for the script
  - `supported_commands/0` - Returns list of commands this adapter supports
  - `validate_command/2` - Validates a command and its arguments

  ## Optional Callbacks

  - `process_response/2` - Post-process responses from the external process
  - `prepare_args/2` - Pre-process arguments before sending to external process

  ## Example Implementation

      defmodule MyApp.PythonMLAdapter do
        @behaviour Snakepit.Adapter
        
        def executable_path, do: System.find_executable("python3") || System.find_executable("python")
        def script_path, do: Path.join(:code.priv_dir(:my_app), "python/ml_bridge.py")
        def script_args, do: ["--mode", "pool-worker"]
        def supported_commands, do: ["predict", "train", "ping"]
        
        def validate_command("predict", args) do
          if Map.has_key?(args, :input), do: :ok, else: {:error, :missing_input}
        end
        def validate_command("ping", _args), do: :ok
        def validate_command(cmd, _), do: {:error, {:unsupported_command, cmd}}
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
  Returns a list of commands that this adapter supports.

  This is used for validation and documentation purposes.
  """
  @callback supported_commands() :: [String.t()]

  @doc """
  Validates that a command and its arguments are valid for this adapter.

  Returns `:ok` if valid, `{:error, reason}` if invalid.
  """
  @callback validate_command(command :: String.t(), args :: map()) ::
              :ok | {:error, term()}

  @doc """
  Optional callback to process responses from the external process.

  This allows adapters to transform or validate responses before
  they're returned to the caller.
  """
  @callback process_response(command :: String.t(), response :: term()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Optional callback to prepare arguments before sending to external process.

  This allows adapters to transform arguments into the format
  expected by their external script.
  """
  @callback prepare_args(command :: String.t(), args :: map()) :: map()

  @optional_callbacks [process_response: 2, prepare_args: 2]

  @doc """
  Default implementation for process_response - just returns the response as-is.
  """
  def default_process_response(_command, response), do: {:ok, response}

  @doc """
  Default implementation for prepare_args - just returns args as-is.
  """
  def default_prepare_args(_command, args), do: args
end
