defmodule Snakepit.Error do
  @moduledoc """
  Structured error type for Snakepit operations.

  Provides detailed context for debugging cross-language and distributed system issues.
  Python exceptions translated from the gRPC bridge are returned as
  `Snakepit.Error.*` exception structs (see `Snakepit.Error.PythonException`).
  `Snakepit.Error` remains the structured error type for Snakepit runtime failures.

  ## Error Categories

  - `:worker` - Worker process errors (not found, crashed, etc.)
  - `:timeout` - Operation timed out
  - `:python_error` - Exception from Python code
  - `:grpc_error` - gRPC communication error
  - `:validation` - Input validation error
  - `:pool` - Pool management error

  ## Examples

      # Create a worker error
      error = Snakepit.Error.worker_error("Worker not found", %{worker_id: "w1"})

      # Create a Python exception error
      error = Snakepit.Error.python_error(
        "ValueError",
        "Invalid input",
        traceback_string,
        %{function: "process_data"}
      )

      # Pattern match in your code
      case Snakepit.execute("command", %{}) do
        {:ok, result} -> result
        {:error, %Snakepit.Error{category: :timeout}} -> retry()
        {:error, %Snakepit.Error{category: :python_error} = error} ->
          Snakepit.Logger.error("Python error: \#{error.message}")
          Snakepit.Logger.debug("Traceback: \#{error.python_traceback}")
        {:error, error} -> {:error, error}
      end
  """

  @type category :: :worker | :timeout | :python_error | :grpc_error | :validation | :pool

  @type t :: %__MODULE__{
          category: category(),
          message: String.t(),
          details: map(),
          python_traceback: String.t() | nil,
          grpc_status: atom() | nil
        }

  defstruct [:category, :message, :details, :python_traceback, :grpc_status]

  @doc """
  Creates a worker-related error.

  ## Examples

      iex> Snakepit.Error.worker_error("Worker crashed")
      %Snakepit.Error{category: :worker, message: "Worker crashed", details: %{}}

      iex> Snakepit.Error.worker_error("Worker not found", %{worker_id: "w1"})
      %Snakepit.Error{category: :worker, message: "Worker not found", details: %{worker_id: "w1"}}
  """
  @spec worker_error(String.t(), map()) :: t()
  def worker_error(message, details \\ %{}) do
    %__MODULE__{
      category: :worker,
      message: message,
      details: details
    }
  end

  @doc """
  Creates a timeout error.

  ## Examples

      iex> Snakepit.Error.timeout_error("Request timed out", %{timeout_ms: 5000})
      %Snakepit.Error{category: :timeout, message: "Request timed out", details: %{timeout_ms: 5000}}
  """
  @spec timeout_error(String.t(), map()) :: t()
  def timeout_error(message, details \\ %{}) do
    %__MODULE__{
      category: :timeout,
      message: message,
      details: details
    }
  end

  @doc """
  Creates a Python exception error with traceback.

  ## Examples

      iex> Snakepit.Error.python_error("ValueError", "Invalid input", "Traceback...")
      %Snakepit.Error{
        category: :python_error,
        message: "ValueError: Invalid input",
        python_traceback: "Traceback...",
        details: %{exception_type: "ValueError"}
      }
  """
  @spec python_error(String.t(), String.t(), String.t(), map()) :: t()
  def python_error(exception_type, message, traceback, details \\ %{}) do
    %__MODULE__{
      category: :python_error,
      message: "#{exception_type}: #{message}",
      details: Map.put(details, :exception_type, exception_type),
      python_traceback: traceback
    }
  end

  @doc """
  Creates a gRPC communication error.

  ## Examples

      iex> Snakepit.Error.grpc_error(:unavailable, "Service unavailable")
      %Snakepit.Error{
        category: :grpc_error,
        message: "Service unavailable",
        grpc_status: :unavailable
      }
  """
  @spec grpc_error(atom(), String.t(), map()) :: t()
  def grpc_error(status, message, details \\ %{}) do
    %__MODULE__{
      category: :grpc_error,
      message: message,
      grpc_status: status,
      details: details
    }
  end

  @doc """
  Creates a pool management error.

  ## Examples

      iex> Snakepit.Error.pool_error("Pool not found", %{pool_name: :test})
      %Snakepit.Error{category: :pool, message: "Pool not found", details: %{pool_name: :test}}
  """
  @spec pool_error(String.t(), map()) :: t()
  def pool_error(message, details \\ %{}) do
    %__MODULE__{
      category: :pool,
      message: message,
      details: details
    }
  end

  @doc """
  Creates a validation error.

  ## Examples

      iex> Snakepit.Error.validation_error("Invalid field", %{field: "user_id"})
      %Snakepit.Error{category: :validation, message: "Invalid field", details: %{field: "user_id"}}
  """
  @spec validation_error(String.t(), map()) :: t()
  def validation_error(message, details \\ %{}) do
    %__MODULE__{
      category: :validation,
      message: message,
      details: details
    }
  end

  defimpl String.Chars do
    def to_string(%Snakepit.Error{} = error) do
      base = "[#{error.category}] #{error.message}"

      details_str =
        if map_size(error.details) > 0 do
          "\nDetails: #{inspect(error.details)}"
        else
          ""
        end

      traceback_str =
        if error.python_traceback do
          "\n\nPython Traceback:\n#{error.python_traceback}"
        else
          ""
        end

      grpc_str =
        if error.grpc_status do
          "\ngRPC Status: #{error.grpc_status}"
        else
          ""
        end

      base <> details_str <> grpc_str <> traceback_str
    end
  end
end
