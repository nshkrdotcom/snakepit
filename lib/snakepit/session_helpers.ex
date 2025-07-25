defmodule Snakepit.SessionHelpers do
  @moduledoc """
  Basic session helpers for cognitive-ready infrastructure.

  This module provides minimal session functionality that delegates
  domain-specific behavior to adapter implementations.

  The cognitive-ready architecture allows adapters to provide enhanced
  session functionality while maintaining clean separation.
  """

  @doc """
  Executes a command in session context with optional adapter enhancement.

  This function delegates to the configured adapter for session management
  if available, otherwise provides basic session affinity.

  ## Examples

      # Basic session execution
      {:ok, result} = Snakepit.SessionHelpers.execute_in_context(
        "my_session", 
        "my_command", 
        %{data: "value"}
      )
  """
  def execute_in_context(session_id, command, args, opts \\ []) do
    # Add session_id to opts for session affinity
    opts_with_session = Keyword.put(opts, :session_id, session_id)

    # Check if adapter provides session enhancement
    adapter_module = Application.get_env(:snakepit, :adapter_module)
    
    enhanced_args = if adapter_module && function_exported?(adapter_module, :enhance_session_args, 3) do
      case adapter_module.enhance_session_args(session_id, command, args) do
        {:ok, enhanced} -> enhanced
        {:error, _} -> args
      end
    else
      args
    end

    # Execute with enhanced arguments
    case Snakepit.execute_in_session(session_id, command, enhanced_args, opts_with_session) do
      {:ok, response} ->
        # Allow adapter to handle post-processing
        if adapter_module && function_exported?(adapter_module, :handle_session_response, 4) do
          case adapter_module.handle_session_response(session_id, command, args, response) do
            {:ok, processed_response} -> {:ok, processed_response}
            {:error, _} -> {:ok, response}  # Fallback to original response
          end
        else
          {:ok, response}
        end

      result ->
        result
    end
  end

  @doc """
  Get session statistics from the adapter if available.
  """
  def get_session_stats(session_id) do
    adapter_module = Application.get_env(:snakepit, :adapter_module)
    
    if adapter_module && function_exported?(adapter_module, :get_session_stats, 1) do
      adapter_module.get_session_stats(session_id)
    else
      {:error, :not_supported}
    end
  end

  @doc """
  Clear session data through the adapter if available.
  """
  def clear_session(session_id) do
    adapter_module = Application.get_env(:snakepit, :adapter_module)
    
    if adapter_module && function_exported?(adapter_module, :clear_session, 1) do
      adapter_module.clear_session(session_id)
    else
      {:error, :not_supported}
    end
  end
end
