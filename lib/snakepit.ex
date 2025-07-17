defmodule Snakepit do
  @moduledoc """
  Snakepit - A generalized high-performance pooler and session manager.

  Extracted from DSPex V3 pool implementation, Snakepit provides:
  - Concurrent worker initialization and management
  - Stateless pool system with session affinity 
  - Generalized adapter pattern for multiple ML frameworks
  - High-performance OTP-based process management

  ## Basic Usage

      # Start a pool
      {:ok, _} = Snakepit.Pool.start_link(size: 4)
      
      # Execute commands
      {:ok, result} = Snakepit.Pool.execute("ping", %{test: true})
      
      # Session-based execution
      {:ok, result} = Snakepit.Pool.execute_in_session("my_session", "command", %{})
  """

  @doc """
  Convenience function to execute commands on the default pool.
  """
  def execute(command, args, opts \\ []) do
    Snakepit.Pool.execute(command, args, opts)
  end

  @doc """
  Convenience function to execute commands in a session context.
  """
  def execute_in_session(session_id, command, args, opts \\ []) do
    Snakepit.Pool.execute_in_session(session_id, command, args, opts)
  end

  @doc """
  Get pool statistics.
  """
  def get_stats(pool \\ Snakepit.Pool) do
    Snakepit.Pool.get_stats(pool)
  end
end
