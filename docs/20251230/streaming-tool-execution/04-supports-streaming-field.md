# Optional: First-Class `supports_streaming` Field

## Overview

This optional enhancement adds `supports_streaming` as a first-class field in `InternalToolSpec` rather than relying on metadata lookup.

## Current Approach

**Location:** `lib/snakepit/bridge/tool_registry.ex:1-28`

```elixir
defmodule Snakepit.Bridge.InternalToolSpec do
  defstruct name: nil,
            type: nil,
            handler: nil,
            worker_id: nil,
            parameters: [],
            description: "",
            metadata: %{},
            exposed_to_python: false

  @type t :: %__MODULE__{
          name: String.t(),
          type: :local | :remote,
          handler: (any() -> any()) | nil,
          worker_id: String.t() | nil,
          parameters: list(map()),
          description: String.t(),
          metadata: map(),
          exposed_to_python: boolean()
        }
end
```

Currently, streaming support is checked via metadata:

```elixir
# In bridge_server.ex
defp tool_supports_streaming?(%{metadata: metadata}) when is_map(metadata) do
  value = Map.get(metadata, "supports_streaming") || Map.get(metadata, :supports_streaming)
  # ...
end
```

## Proposed Enhancement

### Updated InternalToolSpec

```elixir
defmodule Snakepit.Bridge.InternalToolSpec do
  @moduledoc """
  Internal specification for a tool in the registry.
  Separate from the protobuf ToolSpec to avoid conflicts.
  """

  defstruct name: nil,
            type: nil,
            handler: nil,
            worker_id: nil,
            parameters: [],
            description: "",
            metadata: %{},
            exposed_to_python: false,
            supports_streaming: false  # NEW FIELD

  @type t :: %__MODULE__{
          name: String.t(),
          type: :local | :remote,
          handler: (any() -> any()) | nil,
          worker_id: String.t() | nil,
          parameters: list(map()),
          description: String.t(),
          metadata: map(),
          exposed_to_python: boolean(),
          supports_streaming: boolean()  # NEW FIELD
        }
end
```

### Update Tool Registration

#### In `build_remote_tool_spec/1`

```elixir
defp build_remote_tool_spec(spec) do
  metadata = Map.get(spec, :metadata, %{})

  with {:ok, normalized_name} <- validate_tool_name(Map.get(spec, :name)),
       {:ok, normalized_metadata} <- validate_metadata(metadata) do
    {:ok,
     %InternalToolSpec{
       name: normalized_name,
       type: :remote,
       worker_id: Map.get(spec, :worker_id),
       parameters: Map.get(spec, :parameters, []),
       description: Map.get(spec, :description, ""),
       metadata: normalized_metadata,
       supports_streaming: extract_streaming_support(normalized_metadata)  # NEW
     }}
  else
    {:error, _} = error -> error
  end
end

defp extract_streaming_support(metadata) when is_map(metadata) do
  value = Map.get(metadata, "supports_streaming") || Map.get(metadata, :supports_streaming)

  case value do
    true -> true
    "true" -> true
    "1" -> true
    1 -> true
    _ -> false
  end
end

defp extract_streaming_support(_), do: false
```

#### In `register_python_tool/4`

```elixir
def handle_call({:register_python_tool, session_id, tool_name, worker_id, metadata}, _from, state) do
  with {:ok, normalized_name} <- validate_tool_name(tool_name),
       {:ok, normalized_metadata} <- validate_metadata(metadata),
       :ok <- ensure_tool_not_registered(session_id, normalized_name) do
    tool_spec = %InternalToolSpec{
      name: normalized_name,
      type: :remote,
      worker_id: worker_id,
      parameters: Map.get(normalized_metadata, :parameters, []),
      description: Map.get(normalized_metadata, :description, ""),
      metadata: normalized_metadata,
      supports_streaming: extract_streaming_support(normalized_metadata)  # NEW
    }
    # ...
  end
end
```

### Simplified Streaming Check in BridgeServer

```elixir
# Old approach (metadata lookup)
defp tool_supports_streaming?(%{metadata: metadata}) when is_map(metadata) do
  value = Map.get(metadata, "supports_streaming") || Map.get(metadata, :supports_streaming)
  case value do
    true -> true
    "true" -> true
    # ...
  end
end

# New approach (direct field access)
defp tool_supports_streaming?(%{supports_streaming: true}), do: true
defp tool_supports_streaming?(_), do: false
```

## Benefits

| Benefit | Description |
|---------|-------------|
| **Type Safety** | Compile-time checking of the field |
| **Self-Documenting** | Struct definition clearly shows streaming capability |
| **Performance** | Direct struct access vs map lookup chain |
| **Pattern Matching** | Cleaner pattern matching in function heads |
| **Consistency** | Aligns with `exposed_to_python` field pattern |

## Trade-offs

| Consideration | Impact |
|---------------|--------|
| **Migration** | Existing tools registered before upgrade need re-registration |
| **Backwards Compatibility** | Metadata-based lookup still works as fallback |
| **Proto Sync** | Keep `ToolSpec.supports_streaming` in sync |

## Implementation Priority

This is **optional** because:

1. The metadata-based approach works correctly
2. The streaming implementation doesn't depend on this change
3. Can be done as a follow-up enhancement

**Recommendation:** Implement after the core streaming feature is working.

## Tests

```elixir
describe "InternalToolSpec supports_streaming field" do
  test "defaults to false" do
    spec = %InternalToolSpec{}
    refute spec.supports_streaming
  end

  test "set during python tool registration" do
    {:ok, _} = ToolRegistry.register_python_tool(
      "session_1",
      "streaming_tool",
      "worker_1",
      %{"supports_streaming" => "true"}
    )

    {:ok, tool} = ToolRegistry.get_tool("session_1", "streaming_tool")
    assert tool.supports_streaming == true
  end

  test "handles various truthy values" do
    # String "true"
    {:ok, _} = ToolRegistry.register_python_tool("s1", "t1", "w1", %{"supports_streaming" => "true"})
    {:ok, t1} = ToolRegistry.get_tool("s1", "t1")
    assert t1.supports_streaming

    # Boolean true
    {:ok, _} = ToolRegistry.register_python_tool("s2", "t2", "w2", %{supports_streaming: true})
    {:ok, t2} = ToolRegistry.get_tool("s2", "t2")
    assert t2.supports_streaming

    # String "1"
    {:ok, _} = ToolRegistry.register_python_tool("s3", "t3", "w3", %{"supports_streaming" => "1"})
    {:ok, t3} = ToolRegistry.get_tool("s3", "t3")
    assert t3.supports_streaming
  end

  test "defaults to false for missing or falsy values" do
    {:ok, _} = ToolRegistry.register_python_tool("s1", "t1", "w1", %{})
    {:ok, t1} = ToolRegistry.get_tool("s1", "t1")
    refute t1.supports_streaming

    {:ok, _} = ToolRegistry.register_python_tool("s2", "t2", "w2", %{"supports_streaming" => "false"})
    {:ok, t2} = ToolRegistry.get_tool("s2", "t2")
    refute t2.supports_streaming
  end
end
```
