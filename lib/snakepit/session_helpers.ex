defmodule Snakepit.SessionHelpers do
  @moduledoc """
  Session helpers for ML/DSP workflows with program management.

  This module provides domain-specific session functionality for ML frameworks
  that use program creation and execution patterns (like DSPy, LangChain, etc.).

  For generic session management, use `Snakepit.execute_in_session/4` directly.
  """

  require Logger
  alias Snakepit.Logger, as: SLog

  @doc """
  Executes a command in session context with ML program management.

  This function enhances the arguments with session data and handles
  post-processing like storing program metadata for session continuity.

  ## Examples

      # Create a program and store metadata
      {:ok, response} = Snakepit.SessionHelpers.execute_program_command(
        "my_session", 
        "create_program", 
        %{signature: "input -> output"}
      )

      # Execute a program using stored metadata
      {:ok, result} = Snakepit.SessionHelpers.execute_program_command(
        "my_session",
        "execute_program", 
        %{program_id: "123", input: "data"}
      )
  """
  def execute_program_command(session_id, command, args, opts \\ []) do
    # Enhance args with session data
    enhanced_args = enhance_args_with_program_data(args, session_id, command)

    # Add session_id to opts for session affinity
    opts_with_session = Keyword.put(opts, :session_id, session_id)

    case Snakepit.execute_in_session(session_id, command, enhanced_args, opts_with_session) do
      {:ok, response} when command == "create_program" ->
        # Store program data in SessionStore after creation
        case store_program_data_after_creation(session_id, args, response) do
          {:error, reason} ->
            SLog.warning("Program created but failed to store metadata: #{inspect(reason)}")

          :ok ->
            :ok
        end

        {:ok, response}

      result ->
        result
    end
  end

  # Private helper functions

  # Enhanced args with program data from session
  defp enhance_args_with_program_data(args, session_id, command) do
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
  defp store_program_data_after_creation(session_id, _create_args, create_response)
       when is_binary(session_id) and session_id != "anonymous" do
    case Map.get(create_response, "program_id") do
      nil ->
        :ok

      program_id ->
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

  defp store_program_data_after_creation(_session_id, _create_args, _create_response), do: :ok

  # Store program in SessionStore
  defp store_program_in_session(session_id, program_id, program_data)
       when is_binary(session_id) and session_id != "anonymous" do
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
    end
  end

  defp store_program_in_session(_session_id, _program_id, _program_data), do: :ok
end
