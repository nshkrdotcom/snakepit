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
  Executes a command in session context with enhanced args.

  This function enhances the arguments with session data and handles
  post-processing like storing program metadata for session continuity.
  """
  def execute_in_session(session_id, command, args, opts \\ []) do
    # Enhance args with session data
    enhanced_args = enhance_args_with_session_data(args, session_id, command)

    case execute(command, enhanced_args, opts) do
      {:ok, response} when command == "create_program" ->
        # Store program data in SessionStore after creation
        case store_program_data_after_creation(session_id, args, response) do
          {:error, reason} ->
            require Logger
            Logger.warning("Program created but failed to store metadata: #{inspect(reason)}")

          :ok ->
            :ok
        end

        {:ok, response}

      result ->
        result
    end
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

  # Private session-related helper functions

  # Enhanced args with session data
  defp enhance_args_with_session_data(args, session_id, command) do
    base_args =
      if session_id,
        do: Map.put(args, :session_id, session_id),
        else: Map.put(args, :session_id, "anonymous")

    # For execute_program commands, fetch program data from SessionStore
    if command == "execute_program" do
      program_id = Map.get(args, :program_id)

      case Snakepit.Bridge.SessionStore.get_program(session_id, program_id) do
        {:ok, program_data} ->
          Map.put(base_args, :program_data, program_data)

        {:error, _reason} ->
          # Program not found in session store - let external process handle the error
          base_args
      end
    else
      base_args
    end
  end

  # Store program data after creation
  defp store_program_data_after_creation(session_id, _create_args, create_response) do
    if session_id != nil and session_id != "anonymous" do
      program_id = Map.get(create_response, "program_id")

      if program_id do
        # Extract complete serializable program data from external process response
        program_data = %{
          program_id: program_id,
          signature_def:
            Map.get(create_response, "signature_def", Map.get(create_response, "signature", %{})),
          signature_class: Map.get(create_response, "signature_class"),
          field_mapping: Map.get(create_response, "field_mapping", %{}),
          fallback_used: Map.get(create_response, "fallback_used", false),
          created_at: System.system_time(:second),
          execution_count: 0,
          last_executed: nil,
          program_type: Map.get(create_response, "program_type", "predict"),
          signature: Map.get(create_response, "signature", %{})
        }

        store_program_in_session(session_id, program_id, program_data)
      end
    end
  end

  # Store program in SessionStore
  defp store_program_in_session(session_id, program_id, program_data) do
    if session_id != nil and session_id != "anonymous" do
      case Snakepit.Bridge.SessionStore.get_session(session_id) do
        {:ok, _session} ->
          # Update existing session
          Snakepit.Bridge.SessionStore.store_program(session_id, program_id, program_data)

        {:error, :not_found} ->
          # Create new session with program
          case Snakepit.Bridge.SessionStore.create_session(session_id) do
            {:ok, _session} ->
              Snakepit.Bridge.SessionStore.store_program(session_id, program_id, program_data)

            error ->
              error
          end

        error ->
          error
      end
    else
      :ok
    end
  end
end
