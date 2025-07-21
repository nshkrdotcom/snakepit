defmodule Snakepit do
  @moduledoc """
  Snakepit - A generalized high-performance pooler and session manager.

  Extracted from DSPex V3 pool implementation, Snakepit provides:
  - Concurrent worker initialization and management
  - Stateless pool system with session affinity 
  - Generalized adapter pattern for any external process
  - High-performance OTP-based process management

  ## Basic Usage

      # Configure in config/config.exs
      config :snakepit,
        pooling_enabled: true,
        adapter_module: YourAdapter

      # Execute commands on any available worker
      {:ok, result} = Snakepit.execute("ping", %{test: true})
      
      # Session-based execution with worker affinity
      {:ok, result} = Snakepit.execute_in_session("my_session", "command", %{})

  ## Domain-Specific Helpers

  For ML/DSP workflows with program management, see `Snakepit.SessionHelpers`:

      # ML program creation and execution
      {:ok, result} = Snakepit.SessionHelpers.execute_program_command(
        "session_id", "create_program", %{signature: "input -> output"}
      )
  """

  @doc """
  Convenience function to execute commands on the pool.
  """
  def execute(command, args, opts \\ []) do
    Snakepit.Pool.execute(command, args, opts)
  end

  @doc """
  Executes a command in session context with worker affinity.

  This function executes commands with session-based worker affinity,
  ensuring that subsequent calls with the same session_id prefer
  the same worker when possible for state continuity.

  Args are passed through unchanged - no domain-specific enhancement.
  For ML/DSP program workflows, use `Snakepit.SessionHelpers.execute_program_command/4`.
  """
  def execute_in_session(session_id, command, args, opts \\ []) do
    # Add session_id to opts for session affinity
    opts_with_session = Keyword.put(opts, :session_id, session_id)

    # Execute command with session affinity (no args enhancement)
    execute(command, args, opts_with_session)
  end

  @doc """
  Get pool statistics.
  """
  def get_stats(pool \\ Snakepit.Pool) do
    Snakepit.Pool.get_stats(pool)
  end

  @doc """
  List workers from the pool.
  """
  def list_workers(pool \\ Snakepit.Pool) do
    Snakepit.Pool.list_workers(pool)
  end

  @doc """
  Executes a streaming command with a callback function.

  ## Examples

      Snakepit.execute_stream("batch_inference", %{items: [...]}, fn chunk ->
        IO.puts("Received: \#{inspect(chunk)}")
      end)

  ## Options

    * `:pool` - The pool to use (default: `Snakepit.Pool`)
    * `:timeout` - Request timeout in ms (default: 300000)
    * `:session_id` - Run in a specific session

  ## Returns

  Returns `:ok` on success or `{:error, reason}` on failure.

  Note: Streaming is only supported with gRPC adapters.
  """
  @spec execute_stream(String.t(), map(), function(), keyword()) :: :ok | {:error, term()}
  def execute_stream(command, args \\ %{}, callback_fn, opts \\ []) do
    ensure_started!()

    adapter = Application.get_env(:snakepit, :adapter_module)

    unless function_exported?(adapter, :uses_grpc?, 0) and adapter.uses_grpc?() do
      {:error, :streaming_not_supported}
    else
      Snakepit.Pool.execute_stream(command, args, callback_fn, opts)
    end
  end

  @doc """
  Executes a command in a session with a callback function.
  """
  @spec execute_in_session_stream(String.t(), String.t(), map(), function(), keyword()) ::
          :ok | {:error, term()}
  def execute_in_session_stream(session_id, command, args \\ %{}, callback_fn, opts \\ []) do
    ensure_started!()

    adapter = Application.get_env(:snakepit, :adapter_module)

    unless function_exported?(adapter, :uses_grpc?, 0) and adapter.uses_grpc?() do
      {:error, :streaming_not_supported}
    else
      opts_with_session = Keyword.put(opts, :session_id, session_id)
      Snakepit.Pool.execute_stream(command, args, callback_fn, opts_with_session)
    end
  end

  defp ensure_started! do
    case Application.ensure_all_started(:snakepit) do
      {:ok, _} -> :ok
      {:error, _} -> raise "Snakepit application not started"
    end
  end

  # Note: For ML/DSP program management functionality, see Snakepit.SessionHelpers
end
