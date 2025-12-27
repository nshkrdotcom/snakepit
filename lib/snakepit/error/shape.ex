defmodule Snakepit.Error.ShapeMismatch do
  @moduledoc """
  Shape mismatch error for tensor operations.

  Contains detailed information about the shape mismatch including
  which dimension differs and what the expected vs actual values were.
  """

  defexception [
    :expected,
    :got,
    :dimension,
    :expected_dim,
    :got_dim,
    :operation,
    :message
  ]

  @type t :: %__MODULE__{
          expected: [integer()] | nil,
          got: [integer()] | nil,
          dimension: non_neg_integer() | nil,
          expected_dim: integer() | nil,
          got_dim: integer() | nil,
          operation: String.t() | nil,
          message: String.t()
        }

  @impl true
  def message(%__MODULE__{message: msg}) when is_binary(msg), do: msg

  def message(%__MODULE__{} = error) do
    build_message(error)
  end

  defp build_message(%{expected: expected, got: got, operation: op, dimension: dim}) do
    base =
      if dim do
        "Shape mismatch in #{op || "operation"}: dimension #{dim} expected #{inspect(expected)}, got #{inspect(got)}"
      else
        "Shape mismatch in #{op || "operation"}: expected #{inspect(expected)}, got #{inspect(got)}"
      end

    base
  end
end

defmodule Snakepit.Error.Shape do
  @moduledoc """
  Shape error creation helpers.

  Provides functions for creating detailed shape mismatch errors
  with automatic dimension detection and telemetry emission.
  """

  alias Snakepit.Error.ShapeMismatch

  @doc """
  Creates a shape mismatch error.

  Automatically detects which dimension differs and emits telemetry.

  ## Examples

      error = Shape.shape_mismatch([3, 224, 224], [3, 256, 256], "conv2d")
  """
  @spec shape_mismatch([integer()], [integer()], String.t()) :: ShapeMismatch.t()
  def shape_mismatch(expected, got, operation) when is_list(expected) and is_list(got) do
    {dimension, expected_dim, got_dim} = find_mismatch(expected, got)

    message =
      if length(expected) != length(got) do
        "Shape mismatch in #{operation}: rank mismatch - expected #{length(expected)} dimensions #{inspect(expected)}, got #{length(got)} dimensions #{inspect(got)}"
      else
        "Shape mismatch in #{operation}: expected #{inspect(expected)}, got #{inspect(got)}"
      end

    error = %ShapeMismatch{
      expected: expected,
      got: got,
      dimension: dimension,
      expected_dim: expected_dim,
      got_dim: got_dim,
      operation: operation,
      message: message
    }

    emit_telemetry(error)
    error
  end

  @doc """
  Creates a dimension-specific mismatch error.

  Use when you know exactly which dimension has the mismatch.
  """
  @spec dimension_mismatch(non_neg_integer(), integer(), integer(), String.t()) ::
          ShapeMismatch.t()
  def dimension_mismatch(dimension, expected_dim, got_dim, operation) do
    message =
      "Shape mismatch in #{operation}: dimension #{dimension} expected #{expected_dim}, got #{got_dim}"

    error = %ShapeMismatch{
      expected: nil,
      got: nil,
      dimension: dimension,
      expected_dim: expected_dim,
      got_dim: got_dim,
      operation: operation,
      message: message
    }

    emit_telemetry(error)
    error
  end

  @doc """
  Creates a broadcast error.

  Use when shapes cannot be broadcast together.
  """
  @spec broadcast_error([integer()], [integer()], String.t()) :: ShapeMismatch.t()
  def broadcast_error(shape1, shape2, operation) do
    message =
      "Cannot broadcast shapes #{inspect(shape1)} and #{inspect(shape2)} in #{operation}"

    error = %ShapeMismatch{
      expected: shape1,
      got: shape2,
      dimension: nil,
      expected_dim: nil,
      got_dim: nil,
      operation: operation,
      message: message
    }

    emit_telemetry(error)
    error
  end

  @spec find_mismatch([integer()], [integer()]) ::
          {non_neg_integer() | nil, integer() | nil, integer() | nil}
  defp find_mismatch(expected, got) do
    if length(expected) != length(got) do
      {nil, nil, nil}
    else
      expected
      |> Enum.zip(got)
      |> Enum.with_index()
      |> Enum.find(fn {{e, g}, _idx} -> e != g end)
      |> case do
        nil -> {nil, nil, nil}
        {{e, g}, idx} -> {idx, e, g}
      end
    end
  end

  defp emit_telemetry(%ShapeMismatch{} = error) do
    :telemetry.execute(
      [:snakepit, :error, :shape_mismatch],
      %{},
      %{
        expected: error.expected,
        got: error.got,
        dimension: error.dimension,
        operation: error.operation
      }
    )
  end
end
