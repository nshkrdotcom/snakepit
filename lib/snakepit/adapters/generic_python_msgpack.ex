defmodule Snakepit.Adapters.GenericPythonMsgpack do
  @moduledoc """
  Generic Python adapter for Snakepit using MessagePack protocol.

  This adapter uses the v2 bridge with MessagePack support for improved performance:
  - 1.3-2.3x faster for regular data
  - 55x faster for binary data
  - 18-36% smaller message sizes

  ## Configuration

      config :snakepit,
        adapter_module: Snakepit.Adapters.GenericPythonMsgpack

  ## Supported Commands

  Same as GenericPython adapter:
  - `ping` - Health check and basic info
  - `echo` - Echo arguments back (useful for testing)
  - `compute` - Simple math operations (add, subtract, multiply, divide)
  - `info` - Bridge and system information
  """

  @behaviour Snakepit.Adapter

  @impl true
  def executable_path do
    System.find_executable("python3") || System.find_executable("python")
  end

  @impl true
  def script_path do
    # Use the v2 bridge that supports MessagePack
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
    ["--mode", "pool-worker"]
  end

  @impl true
  def supported_commands do
    ["ping", "echo", "compute", "info", "store", "retrieve"]
  end

  @impl true
  def validate_command(command, _args) do
    if command in supported_commands() do
      :ok
    else
      {:error, "Unsupported command: #{command}"}
    end
  end
end
