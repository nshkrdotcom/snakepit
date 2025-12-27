# Structured Exception Protocol

## Overview

This document specifies Snakepit's structured exception protocol, enabling pattern-matchable error handling with ML-specific context like tensor shapes, dtypes, and device information.

## Problem Statement

Python errors are currently text blobs:

```elixir
{:error, "ValueError: shapes (3,4) and (2,2) not aligned"}
```

ML practitioners need:
- Pattern matching on error types
- Shape/dtype information in structured form
- Device context (which GPU OOMed?)
- Actionable suggestions

## Design Goals

1. **Pattern-matchable**: Elixir developers can match on error types
2. **Context-rich**: Include shapes, dtypes, devices
3. **Suggestion-aware**: Provide likely fixes
4. **Traceback-preserving**: Keep Python stack traces

## Error Type Hierarchy

```
Snakepit.Error (base)
├── Snakepit.Error.Python (Python exception wrapper)
│   ├── ValueError
│   ├── TypeError
│   ├── KeyError
│   ├── IndexError
│   ├── AttributeError
│   ├── ImportError
│   ├── RuntimeError
│   └── ...
├── Snakepit.Error.Shape (tensor shape errors)
│   ├── ShapeMismatch
│   ├── BroadcastError
│   └── DimensionError
├── Snakepit.Error.Dtype (type errors)
│   ├── DtypeMismatch
│   └── UnsupportedDtype
├── Snakepit.Error.Device (GPU/device errors)
│   ├── OutOfMemory
│   ├── DeviceNotAvailable
│   └── DeviceMismatch
├── Snakepit.Error.Serialization
│   ├── EncodingError
│   └── DecodingError
└── Snakepit.Error.Worker
    ├── Timeout
    ├── Crash
    └── Unavailable
```

## Exception Definitions

### Base Error

```elixir
defmodule Snakepit.Error do
  @moduledoc """
  Base error type for all Snakepit errors.
  """

  @type t :: %__MODULE__{
    type: atom(),
    message: String.t(),
    python_type: String.t() | nil,
    python_traceback: String.t() | nil,
    context: map(),
    suggestion: String.t() | nil
  }

  defexception [
    :type,
    :message,
    :python_type,
    :python_traceback,
    :context,
    :suggestion
  ]

  @impl Exception
  def message(%__MODULE__{} = error) do
    base = "#{error.type}: #{error.message}"

    parts = [base]

    parts = if error.suggestion do
      parts ++ ["\n\nSuggestion: #{error.suggestion}"]
    else
      parts
    end

    parts = if error.python_traceback && Application.get_env(:snakepit, :show_python_traceback, true) do
      parts ++ ["\n\nPython traceback:\n#{error.python_traceback}"]
    else
      parts
    end

    Enum.join(parts)
  end

  @doc """
  Creates an error from Python exception data.
  """
  @spec from_python(map()) :: t()
  def from_python(data) when is_map(data) do
    python_type = Map.get(data, "type") || Map.get(data, :type, "UnknownError")
    message = Map.get(data, "message") || Map.get(data, :message, "Unknown error")
    traceback = Map.get(data, "traceback") || Map.get(data, :traceback)
    context = Map.get(data, "context") || Map.get(data, :context, %{})

    {type, suggestion} = classify_and_suggest(python_type, message, context)

    %__MODULE__{
      type: type,
      message: message,
      python_type: python_type,
      python_traceback: traceback,
      context: context,
      suggestion: suggestion
    }
  end

  defp classify_and_suggest(python_type, message, context) do
    cond do
      # Shape errors
      shape_error?(message) ->
        {:shape_mismatch, shape_suggestion(message, context)}

      # OOM errors
      oom_error?(python_type, message) ->
        {:out_of_memory, oom_suggestion(context)}

      # Dtype errors
      dtype_error?(message) ->
        {:dtype_mismatch, dtype_suggestion(message, context)}

      # Device errors
      device_error?(message) ->
        {:device_mismatch, device_suggestion(message)}

      # Import errors
      python_type in ["ModuleNotFoundError", "ImportError"] ->
        {:import_error, "Run: mix snakebridge.setup"}

      # Generic Python errors
      true ->
        {String.to_atom(Macro.underscore(python_type)), nil}
    end
  end

  defp shape_error?(message) do
    String.contains?(message, ["shape", "dimension", "size"]) and
    (String.contains?(message, ["mismatch", "not aligned", "incompatible", "broadcast"]))
  end

  defp oom_error?(type, message) do
    type == "RuntimeError" and
    (String.contains?(message, ["out of memory", "CUDA", "OOM"]))
  end

  defp dtype_error?(message) do
    String.contains?(message, ["dtype", "type"]) and
    String.contains?(message, ["expected", "got", "mismatch"])
  end

  defp device_error?(message) do
    String.contains?(message, ["device", "cuda", "cpu"]) and
    String.contains?(message, ["expected", "different"])
  end

  defp shape_suggestion(message, context) do
    shapes = extract_shapes(message, context)

    case shapes do
      {a, b} when length(a) != length(b) ->
        "Dimension mismatch: #{inspect(a)} has #{length(a)} dims, " <>
        "#{inspect(b)} has #{length(b)} dims. Check broadcasting rules."

      {a, b} ->
        mismatched = find_mismatched_dims(a, b)
        "Shapes #{inspect(a)} and #{inspect(b)} differ at dimension #{mismatched}. " <>
        "Try transposing or reshaping one of the tensors."

      nil ->
        "Check that tensor shapes are compatible for the operation."
    end
  end

  defp oom_suggestion(context) do
    device = Map.get(context, :device) || Map.get(context, "device")
    """
    GPU out of memory on #{inspect(device)}.
    Options:
    1. Reduce batch size
    2. Use gradient checkpointing
    3. Move to CPU with device: :cpu option
    4. Use mixed precision (float16)
    """
  end

  defp dtype_suggestion(message, _context) do
    dtypes = Regex.scan(~r/(float\d+|int\d+|bool|bfloat16)/i, message)
    |> Enum.map(&List.first/1)
    |> Enum.uniq()

    case dtypes do
      [expected, got] ->
        "Expected #{expected} but got #{got}. " <>
        "Cast with .to(torch.#{expected}) or use dtype=torch.#{expected}."
      _ ->
        "Check tensor dtypes match. Use .dtype to inspect and .to() to convert."
    end
  end

  defp device_suggestion(message) do
    if String.contains?(message, "expected cuda") do
      "Tensor is on CPU but operation expects CUDA. Use .cuda() or .to('cuda')."
    else
      "Tensor is on CUDA but operation expects CPU. Use .cpu() or .to('cpu')."
    end
  end

  defp extract_shapes(message, context) do
    # Try context first
    case {Map.get(context, :shape_a), Map.get(context, :shape_b)} do
      {a, b} when is_list(a) and is_list(b) -> {a, b}
      _ ->
        # Parse from message
        case Regex.scan(~r/\(([0-9,\s]+)\)/, message) do
          [[_, a], [_, b] | _] ->
            {parse_shape(a), parse_shape(b)}
          _ ->
            nil
        end
    end
  end

  defp parse_shape(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_integer/1)
  end

  defp find_mismatched_dims(a, b) do
    Enum.zip(a, b)
    |> Enum.with_index()
    |> Enum.find(fn {{x, y}, _idx} -> x != y and x != 1 and y != 1 end)
    |> case do
      {{_, _}, idx} -> idx
      nil -> 0
    end
  end
end
```

### Shape Error

```elixir
defmodule Snakepit.Error.Shape do
  @moduledoc """
  Errors related to tensor shape mismatches.
  """

  @type t :: %__MODULE__{
    message: String.t(),
    shape_a: [non_neg_integer()] | nil,
    shape_b: [non_neg_integer()] | nil,
    operation: atom() | nil,
    suggestion: String.t() | nil
  }

  defexception [:message, :shape_a, :shape_b, :operation, :suggestion]

  @impl Exception
  def message(%__MODULE__{} = error) do
    base = "Shape mismatch: #{error.message}"

    shapes = if error.shape_a && error.shape_b do
      "\n  Shape A: #{inspect(error.shape_a)}\n  Shape B: #{inspect(error.shape_b)}"
    else
      ""
    end

    suggestion = if error.suggestion do
      "\n\nSuggestion: #{error.suggestion}"
    else
      ""
    end

    base <> shapes <> suggestion
  end

  @doc """
  Creates a shape error from Python context.
  """
  @spec from_context(String.t(), map()) :: t()
  def from_context(message, context) do
    shape_a = Map.get(context, :shape_a) || Map.get(context, "shape_a")
    shape_b = Map.get(context, :shape_b) || Map.get(context, "shape_b")
    operation = Map.get(context, :operation) || Map.get(context, "operation")

    suggestion = generate_suggestion(shape_a, shape_b, operation)

    %__MODULE__{
      message: message,
      shape_a: shape_a,
      shape_b: shape_b,
      operation: operation && String.to_atom(operation),
      suggestion: suggestion
    }
  end

  defp generate_suggestion(nil, nil, _), do: nil
  defp generate_suggestion(a, b, :matmul) when is_list(a) and is_list(b) do
    a_cols = List.last(a)
    b_rows = List.first(b)

    if a_cols != b_rows do
      "For matmul, A columns (#{a_cols}) must equal B rows (#{b_rows}). " <>
      "Try transposing B: torch.transpose(b, 0, 1)"
    else
      nil
    end
  end
  defp generate_suggestion(a, b, _) when is_list(a) and is_list(b) do
    "Shapes #{inspect(a)} and #{inspect(b)} are incompatible. " <>
    "Check operation requirements."
  end
  defp generate_suggestion(_, _, _), do: nil
end
```

### Device Error

```elixir
defmodule Snakepit.Error.Device do
  @moduledoc """
  Errors related to device placement (CPU/GPU).
  """

  @type device :: :cpu | {:cuda, non_neg_integer()} | :mps

  @type t :: %__MODULE__{
    type: :out_of_memory | :device_mismatch | :device_not_available,
    message: String.t(),
    device: device() | nil,
    requested_memory_mb: non_neg_integer() | nil,
    available_memory_mb: non_neg_integer() | nil,
    suggestion: String.t() | nil
  }

  defexception [:type, :message, :device, :requested_memory_mb, :available_memory_mb, :suggestion]

  @impl Exception
  def message(%__MODULE__{type: :out_of_memory} = error) do
    """
    GPU Out of Memory on #{inspect(error.device)}
    Requested: #{error.requested_memory_mb || "unknown"} MB
    Available: #{error.available_memory_mb || "unknown"} MB

    #{error.suggestion || default_oom_suggestion()}
    """
  end

  def message(%__MODULE__{type: :device_mismatch} = error) do
    """
    Device mismatch: #{error.message}
    Expected device: #{inspect(error.device)}

    #{error.suggestion || "Ensure all tensors are on the same device."}
    """
  end

  def message(%__MODULE__{type: :device_not_available} = error) do
    """
    Device not available: #{inspect(error.device)}

    #{error.suggestion || "Check that CUDA/MPS is properly installed and a GPU is present."}
    """
  end

  defp default_oom_suggestion do
    """
    Suggestions:
    1. Reduce batch size
    2. Use gradient checkpointing: model.gradient_checkpointing_enable()
    3. Use mixed precision: with torch.cuda.amp.autocast()
    4. Move to CPU for this operation: tensor.cpu()
    5. Clear cache: torch.cuda.empty_cache()
    """
  end

  @doc """
  Creates OOM error with memory info.
  """
  @spec out_of_memory(device(), keyword()) :: t()
  def out_of_memory(device, opts \\ []) do
    %__MODULE__{
      type: :out_of_memory,
      message: "CUDA out of memory",
      device: device,
      requested_memory_mb: Keyword.get(opts, :requested_mb),
      available_memory_mb: Keyword.get(opts, :available_mb),
      suggestion: Keyword.get(opts, :suggestion)
    }
  end
end
```

## Python-Side Error Extraction

```python
# snakepit/error_extractor.py

import sys
import traceback
import json
from dataclasses import dataclass, asdict
from typing import Optional, Dict, Any
import re


@dataclass
class StructuredError:
    type: str
    message: str
    traceback: str
    context: Dict[str, Any]

    def to_dict(self) -> dict:
        return asdict(self)


def extract_error(exc: BaseException) -> StructuredError:
    """
    Extracts structured error info from a Python exception.
    """
    error_type = type(exc).__name__
    message = str(exc)
    tb = ''.join(traceback.format_exception(type(exc), exc, exc.__traceback__))

    context = extract_context(exc, message)

    return StructuredError(
        type=error_type,
        message=message,
        traceback=tb,
        context=context
    )


def extract_context(exc: BaseException, message: str) -> Dict[str, Any]:
    """
    Extracts ML-specific context from the exception.
    """
    context = {}

    # Try to extract shapes from message
    shapes = extract_shapes(message)
    if shapes:
        if len(shapes) >= 1:
            context['shape_a'] = shapes[0]
        if len(shapes) >= 2:
            context['shape_b'] = shapes[1]

    # Try to extract dtypes
    dtypes = extract_dtypes(message)
    if dtypes:
        context['dtypes'] = dtypes

    # Try to extract device info
    device = extract_device(message)
    if device:
        context['device'] = device

    # For OOM errors, get memory info
    if is_oom_error(exc, message):
        context.update(get_gpu_memory_info())

    return context


def extract_shapes(message: str) -> list:
    """Extracts tensor shapes from error message."""
    # Pattern: (N, M, K) or [N, M, K]
    pattern = r'[\(\[](\d+(?:,\s*\d+)*)[\)\]]'
    matches = re.findall(pattern, message)

    shapes = []
    for match in matches:
        dims = [int(d.strip()) for d in match.split(',')]
        shapes.append(dims)

    return shapes


def extract_dtypes(message: str) -> list:
    """Extracts dtype mentions from error message."""
    dtypes = set()
    patterns = [
        r'torch\.(float\d+|int\d+|bool|bfloat16)',
        r'dtype[=\s]+(float\d+|int\d+|bool)',
        r'expected\s+(float\d+|int\d+)',
    ]

    for pattern in patterns:
        for match in re.findall(pattern, message, re.IGNORECASE):
            dtypes.add(match.lower())

    return list(dtypes)


def extract_device(message: str) -> Optional[str]:
    """Extracts device from error message."""
    if 'cuda:' in message.lower():
        match = re.search(r'cuda:(\d+)', message.lower())
        if match:
            return f"cuda:{match.group(1)}"
        return 'cuda:0'
    elif 'cuda' in message.lower():
        return 'cuda:0'
    elif 'cpu' in message.lower():
        return 'cpu'
    elif 'mps' in message.lower():
        return 'mps'
    return None


def is_oom_error(exc: BaseException, message: str) -> bool:
    """Checks if this is an out-of-memory error."""
    return (
        'out of memory' in message.lower() or
        'CUDA error: out of memory' in message or
        type(exc).__name__ == 'OutOfMemoryError'
    )


def get_gpu_memory_info() -> dict:
    """Gets current GPU memory usage."""
    try:
        import torch
        if torch.cuda.is_available():
            device = torch.cuda.current_device()
            return {
                'allocated_mb': torch.cuda.memory_allocated(device) // (1024 * 1024),
                'reserved_mb': torch.cuda.memory_reserved(device) // (1024 * 1024),
                'max_memory_mb': torch.cuda.get_device_properties(device).total_memory // (1024 * 1024),
            }
    except Exception:
        pass
    return {}


# Error handler for worker
def handle_error(exc: BaseException) -> str:
    """
    Handles an exception and returns JSON-encoded structured error.
    """
    structured = extract_error(exc)
    return json.dumps(structured.to_dict())
```

## Elixir-Side Error Parsing

```elixir
defmodule Snakepit.ErrorParser do
  @moduledoc """
  Parses Python errors into structured Elixir exceptions.
  """

  alias Snakepit.Error
  alias Snakepit.Error.{Shape, Device}

  @spec parse(map()) :: Error.t() | Shape.t() | Device.t()
  def parse(error_data) when is_map(error_data) do
    type = Map.get(error_data, "type") || Map.get(error_data, :type)
    message = Map.get(error_data, "message") || Map.get(error_data, :message, "")
    context = Map.get(error_data, "context") || Map.get(error_data, :context, %{})

    case classify(type, message, context) do
      :shape_mismatch ->
        Shape.from_context(message, context)

      :out_of_memory ->
        device = parse_device(context)
        Device.out_of_memory(device,
          requested_mb: Map.get(context, "allocated_mb"),
          available_mb: Map.get(context, "max_memory_mb")
        )

      :device_mismatch ->
        %Device{
          type: :device_mismatch,
          message: message,
          device: parse_device(context)
        }

      _ ->
        Error.from_python(error_data)
    end
  end

  defp classify(type, message, _context) do
    cond do
      String.contains?(message, ["shape", "dimension"]) and
      String.contains?(message, ["mismatch", "not aligned", "incompatible"]) ->
        :shape_mismatch

      type == "RuntimeError" and String.contains?(message, "out of memory") ->
        :out_of_memory

      String.contains?(message, "Expected") and
      String.contains?(message, ["cuda", "cpu", "device"]) ->
        :device_mismatch

      true ->
        :generic
    end
  end

  defp parse_device(%{"device" => "cuda:" <> id}) do
    {:cuda, String.to_integer(id)}
  end
  defp parse_device(%{"device" => "cuda"}), do: {:cuda, 0}
  defp parse_device(%{"device" => "cpu"}), do: :cpu
  defp parse_device(%{"device" => "mps"}), do: :mps
  defp parse_device(%{device: device}), do: parse_device(%{"device" => device})
  defp parse_device(_), do: nil
end
```

## Usage Examples

```elixir
# Pattern matching on error types
case Snakepit.execute("torch.matmul", %{a: tensor_a, b: tensor_b}) do
  {:ok, result} ->
    result

  {:error, %Snakepit.Error.Shape{shape_a: a, shape_b: b}} ->
    Logger.error("Shape mismatch: #{inspect(a)} vs #{inspect(b)}")
    {:error, :invalid_shapes}

  {:error, %Snakepit.Error.Device{type: :out_of_memory, device: device}} ->
    Logger.warning("OOM on #{inspect(device)}, falling back to CPU")
    Snakepit.execute("torch.matmul", %{a: tensor_a, b: tensor_b}, device: :cpu)

  {:error, %Snakepit.Error{type: :value_error} = e} ->
    Logger.error("ValueError: #{e.message}")
    {:error, :invalid_value}

  {:error, error} ->
    Logger.error("Unexpected error: #{inspect(error)}")
    {:error, :unknown}
end
```

## Configuration

```elixir
config :snakepit, :errors,
  # Show Python tracebacks in error messages
  show_python_traceback: true,

  # Include suggestions
  show_suggestions: true,

  # Log errors at this level
  log_level: :error,

  # Generate repro scripts for errors
  generate_repro: true
```

## Telemetry Integration

```elixir
# Errors emit telemetry
:telemetry.execute(
  [:snakepit, :error],
  %{count: 1},
  %{
    type: :shape_mismatch,
    python_type: "RuntimeError",
    library: "torch",
    function: "matmul"
  }
)
```

## Implementation Phases

### Phase 1: Base Types (Week 1)
- [ ] Define error type hierarchy
- [ ] Implement base Error struct
- [ ] Python error extraction

### Phase 2: ML Errors (Week 2)
- [ ] Shape error parsing
- [ ] Device/OOM errors
- [ ] Dtype errors

### Phase 3: Suggestions (Week 3)
- [ ] Context-aware suggestions
- [ ] Common error patterns
- [ ] Fix recommendations

### Phase 4: Integration (Week 4)
- [ ] Worker error handling
- [ ] Telemetry events
- [ ] Documentation

## SnakeBridge Integration

SnakeBridge uses structured errors for:

1. **Generated wrapper error handling**: Pattern match on error types
2. **Documentation**: Include common errors in generated docs
3. **Type specs**: Include error types in specs

See: `snakebridge/docs/20251227/world-class-ml/03-ml-error-translation.md`
