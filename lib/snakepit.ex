defmodule Snakepit do
  @moduledoc """
  Snakepit - A generalized high-performance pooler and session manager.

  Extracted from DSPex V3 pool implementation, Snakepit provides:
  - Concurrent worker initialization and management
  - Stateless pool system with session affinity 
  - Generalized adapter pattern for multiple ML frameworks
  - High-performance OTP-based process management

  ## Basic Usage

      # Configure in config/config.exs
      config :snakepit,
        pooling_enabled: true,
        adapter_module: YourAdapter

      # Execute commands
      {:ok, result} = Snakepit.execute("ping", %{test: true})
      
      # Session-based execution
      {:ok, result} = Snakepit.execute_in_session("my_session", "command", %{})
  """

  @doc """
  Convenience function to execute commands on the pool.
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

  @doc """
  List workers from the pool.
  """
  def list_workers(pool \\ Snakepit.Pool) do
    Snakepit.Pool.list_workers(pool)
  end
end
