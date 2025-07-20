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
  Execute a command with streaming results.

  The callback function is called for each chunk received from the stream.

  ## Examples

      Snakepit.execute_stream("batch_inference", %{
        items: ["img1.jpg", "img2.jpg"]
      }, fn chunk ->
        IO.puts("Processed: \#{chunk["item"]}")
      end)
  """
  @spec execute_stream(String.t(), map(), function(), keyword()) :: :ok | {:error, term()}
  def execute_stream(command, args \\ %{}, callback, opts \\ []) do
    ensure_started!()

    adapter = Application.get_env(:snakepit, :adapter_module)

    unless function_exported?(adapter, :uses_grpc?, 0) and adapter.uses_grpc?() do
      {:error, :streaming_not_supported}
    else
      Snakepit.Pool.execute_stream(command, args, callback, opts)
    end
  end

  @doc """
  Execute a command in a session with streaming results.
  """
  @spec execute_in_session_stream(String.t(), String.t(), map(), function(), keyword()) ::
          :ok | {:error, term()}
  def execute_in_session_stream(session_id, command, args \\ %{}, callback, opts \\ []) do
    ensure_started!()

    adapter = Application.get_env(:snakepit, :adapter_module)

    unless function_exported?(adapter, :uses_grpc?, 0) and adapter.uses_grpc?() do
      {:error, :streaming_not_supported}
    else
      # Add session_id to opts for worker affinity
      opts_with_session = Keyword.put(opts, :session_id, session_id)
      Snakepit.Pool.execute_stream(command, args, callback, opts_with_session)
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
