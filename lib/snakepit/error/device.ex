defmodule Snakepit.Error.DeviceMismatch do
  @moduledoc """
  Device mismatch error for tensor operations.

  Raised when tensors on different devices are used in an operation
  that requires them to be on the same device.
  """

  defexception [
    :expected,
    :got,
    :operation,
    :message
  ]

  @type device :: :cpu | :mps | {:cuda, non_neg_integer()} | {:rocm, non_neg_integer()}

  @type t :: %__MODULE__{
          expected: device() | nil,
          got: device() | nil,
          operation: String.t() | nil,
          message: String.t()
        }

  @impl true
  def message(%__MODULE__{message: msg}), do: msg
end

defmodule Snakepit.Error.OutOfMemory do
  @moduledoc """
  Out of memory error for GPU operations.

  Contains information about the requested allocation, available memory,
  and suggestions for recovery.
  """

  defexception [
    :device,
    :requested_bytes,
    :available_bytes,
    :operation,
    :suggestions,
    :message
  ]

  @type device :: :cpu | :mps | {:cuda, non_neg_integer()} | {:rocm, non_neg_integer()}

  @type t :: %__MODULE__{
          device: device(),
          requested_bytes: non_neg_integer(),
          available_bytes: non_neg_integer(),
          operation: String.t() | nil,
          suggestions: [String.t()],
          message: String.t()
        }

  @impl true
  def message(%__MODULE__{message: msg}), do: msg
end

defmodule Snakepit.Error.Device do
  @moduledoc """
  Device error creation helpers.

  Provides functions for creating device-related errors with
  telemetry emission and helpful suggestions.
  """

  alias Snakepit.Error.{DeviceMismatch, OutOfMemory}

  @doc """
  Creates a device mismatch error.

  ## Examples

      error = Device.device_mismatch(:cpu, {:cuda, 0}, "matmul")
  """
  @spec device_mismatch(term(), term(), String.t()) :: DeviceMismatch.t()
  def device_mismatch(expected, got, operation) do
    message =
      "Device mismatch in #{operation}: expected #{format_device(expected)}, got #{format_device(got)}"

    error = %DeviceMismatch{
      expected: expected,
      got: got,
      operation: operation,
      message: message
    }

    emit_device_telemetry(error)
    error
  end

  @doc """
  Creates a device unavailable error.

  ## Examples

      error = Device.device_unavailable({:cuda, 2}, "matrix_multiply")
  """
  @spec device_unavailable(term(), String.t()) :: DeviceMismatch.t()
  def device_unavailable(device, operation) do
    message = "Device #{format_device(device)} unavailable or not found for #{operation}"

    error = %DeviceMismatch{
      expected: device,
      got: nil,
      operation: operation,
      message: message
    }

    emit_device_telemetry(error)
    error
  end

  @doc """
  Creates an out of memory error with recovery suggestions.

  ## Examples

      error = Device.out_of_memory({:cuda, 0}, 1024 * 1024 * 1024, 512 * 1024 * 1024)
  """
  @spec out_of_memory(term(), non_neg_integer(), non_neg_integer(), String.t() | nil) ::
          OutOfMemory.t()
  def out_of_memory(device, requested_bytes, available_bytes, operation \\ nil) do
    suggestions = generate_oom_suggestions(device, requested_bytes, available_bytes)

    message =
      "OOM on #{format_device(device)}: requested #{format_bytes(requested_bytes)}, " <>
        "available #{format_bytes(available_bytes)}"

    message =
      if operation do
        "#{message} during #{operation}"
      else
        message
      end

    error = %OutOfMemory{
      device: device,
      requested_bytes: requested_bytes,
      available_bytes: available_bytes,
      operation: operation,
      suggestions: suggestions,
      message: message
    }

    emit_oom_telemetry(error)
    error
  end

  defp format_device(:cpu), do: "CPU"
  defp format_device(:mps), do: "MPS"
  defp format_device({:cuda, id}), do: "CUDA:#{id}"
  defp format_device({:rocm, id}), do: "ROCm:#{id}"
  defp format_device(nil), do: "unknown"
  defp format_device(other), do: inspect(other)

  defp format_bytes(bytes) when bytes >= 1_073_741_824 do
    "#{Float.round(bytes / 1_073_741_824, 2)} GB"
  end

  defp format_bytes(bytes) when bytes >= 1_048_576 do
    "#{Float.round(bytes / 1_048_576, 2)} MB"
  end

  defp format_bytes(bytes) when bytes >= 1024 do
    "#{Float.round(bytes / 1024, 2)} KB"
  end

  defp format_bytes(bytes), do: "#{bytes} bytes"

  defp generate_oom_suggestions(device, requested, available) do
    base_suggestions = [
      "Reduce batch size",
      "Use gradient checkpointing",
      "Enable mixed precision training (FP16/BF16)",
      "Free unused tensors with del or gc.collect()"
    ]

    device_suggestions =
      case device do
        {:cuda, _} ->
          [
            "Use torch.cuda.empty_cache() to clear cached memory",
            "Set PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True"
          ]

        :mps ->
          ["Use torch.mps.empty_cache() to clear cached memory"]

        _ ->
          []
      end

    ratio = requested / max(available, 1)

    extreme_suggestions =
      if ratio > 2.0 do
        [
          "Consider model parallelism or offloading to CPU",
          "Use a smaller model architecture"
        ]
      else
        []
      end

    base_suggestions ++ device_suggestions ++ extreme_suggestions
  end

  defp emit_device_telemetry(%DeviceMismatch{} = error) do
    :telemetry.execute(
      [:snakepit, :error, :device],
      %{},
      %{
        expected_device: error.expected,
        actual_device: error.got,
        operation: error.operation
      }
    )
  end

  defp emit_oom_telemetry(%OutOfMemory{} = error) do
    :telemetry.execute(
      [:snakepit, :error, :oom],
      %{
        requested_bytes: error.requested_bytes,
        available_bytes: error.available_bytes
      },
      %{
        device: error.device,
        operation: error.operation
      }
    )
  end
end
