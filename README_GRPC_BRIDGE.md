## **Snakepit gRPC Bridge: Technical Documentation**

### 1. Overview

#### 1.1. Purpose
The Snakepit gRPC bridge is a high-performance, bidirectional communication layer that connects the Elixir host application with external Python worker processes. It replaces traditional `stdin`/`stdout` communication with a robust, schema-driven RPC framework, enabling advanced features like type-safe data exchange, efficient binary serialization, and real-time streaming.

#### 1.2. Key Features
*   **High Performance**: Leverages gRPC over HTTP/2 for low-latency, multiplexed communication.
*   **Type Safety**: Utilizes a Protocol Buffers (`.proto`) schema as the single source of truth for the data contract between Elixir and Python.
*   **Robust Serialization**: A sophisticated serialization layer handles complex Elixir and Python data types, including automatic JSON encoding for nested structures.
*   **Streaming Support**: Natively supports server-side streaming for long-running tasks, progress updates, and large data payloads.
*   **Session Affinity**: The pool intelligently routes requests with the same `session_id` to the same Python worker, enabling stateful workflows.
*   **Extensible Adapter Pattern**: The core logic is decoupled from the specific Python code being run, allowing any Python library or framework to be integrated by creating a new adapter.

---

### 2. System Architecture

The bridge consists of several key components that work in concert to process a request.

```
+--------------------------+      +------------------+      +-------------------+      +---------------------+
|   Elixir Application     |----->|  Snakepit.Pool   |----->| Snakepit.GRPCWorker |----->| Snakepit.GRPC.Client|
| (e.g., SnakepitShowcase) |      | (Manages Workers)|      | (Manages Channel) |      | (Elixir gRPC Facade)|
+--------------------------+      +------------------+      +-------------------+      +----------+----------+
                                                                                                  |
+--------------------------+      +------------------+      +-------------------+                 | (gRPC over HTTP/2)
|      Python Adapter      |<-----| BridgeService    |<-----|  Python gRPC      |<----------------+
| (e.g., ShowcaseAdapter)  |      | (RPC Endpoints)  |      |  Server           |
+--------------------------+      +------------------+      +-------------------+
```

*   **Elixir Application**: The user-facing code that calls `Snakepit.execute` or `Snakepit.execute_stream`.
*   **Snakepit.Pool**: Manages the lifecycle of `GRPCWorker` processes, handling checkouts, check-ins, and request queuing.
*   **Snakepit.GRPCWorker**: An Elixir GenServer responsible for a single Python process. It starts the Python server, manages the gRPC channel (connection), and forwards calls to the `GRPC.Client`.
*   **Snakepit.GRPC.Client / ClientImpl**: The Elixir modules responsible for encoding Elixir terms into Protobuf messages and making the actual gRPC calls.
*   **Python gRPC Server (`grpc_server.py`)**: The Python process that listens for incoming gRPC requests.
*   **BridgeServiceServicer**: The Python class that implements the RPC methods defined in the `.proto` file. It's largely stateless.
*   **Python Adapter**: The user-provided Python class that contains the actual business logic (e.g., ML model inference, data processing).

---

### 3. Core Concept: The Serialization Strategy

The most complex part of the bridge is correctly serializing arbitrary data structures between Elixir and Python. This is accomplished using `google.protobuf.Any`.

*   **What is `Any`?**: An `Any` message is a self-describing container with two fields:
    *   `type_url`: A string that uniquely identifies the type of the packed data (e.g., `type.googleapis.com/google.protobuf.DoubleValue`).
    *   `value`: A byte string containing the serialized data of that type.
*   **Our Strategy**:
    1.  **Simple Types** (`integer`, `float`, `boolean`, `string`): These are encoded using their standard Protobuf wrapper types.
    2.  **Complex Types** (`map`, non-numeric `list`): These are first encoded as a JSON string. This JSON string is then treated as a simple string and packed into a `google.protobuf.StringValue`. This ensures that any arbitrarily complex and nested data structure can be reliably transmitted.
    3.  **Specialized Types** (`tensor`, `embedding`): These are also JSON-encoded as strings, but their `type` is inferred to allow for future optimizations like binary serialization.

This strategy is implemented symmetrically in the Elixir `Snakepit.Bridge.Serialization` module and the Python `snakepit_bridge.serialization.TypeSerializer` class.

---

### 4. Component Deep Dive

#### 4.1. Elixir Side

| File | Component | Role & Responsibilities |
| :--- | :--- | :--- |
| `lib/snakepit/grpc_worker.ex` | `Snakepit.GRPCWorker` | **The Process Manager.** Starts and monitors one `grpc_server.py` process. Establishes and holds the gRPC channel to it. Receives `:execute` and `:execute_stream` calls from the Pool and delegates them. |
| `lib/snakepit/grpc/client.ex` | `Snakepit.GRPC.Client` | **The Public Facade.** Provides the top-level `execute_tool` and `execute_streaming_tool` functions. Contains mock logic for testing and delegates all real calls to `ClientImpl`. |
| `lib/snakepit/grpc/client_impl.ex` | `Snakepit.GRPC.ClientImpl` | **The gRPC Caller.** Contains the core logic for making RPC calls. Its key function, `infer_and_encode_any`, uses `Types.infer_type` to determine how to serialize Elixir terms before building and sending the Protobuf request. It also uses `Serialization.decode_any` to deserialize responses. |
| `lib/snakepit/bridge/variables/types.ex` | `Snakepit.Bridge.Variables.Types` | **The Type Oracle.** The `infer_type/1` function is critical. It inspects an Elixir term and classifies it as `:integer`, `:float`, `:string`, etc. It correctly classifies complex maps and lists as `:string` so they can be JSON-encoded. |
| `lib/snakepit/bridge/serialization.ex` | `Snakepit.Bridge.Serialization` | **The Serializer/Deserializer.** The `encode_any/2` and `decode_any/1` functions are the heart of the data conversion process. `decode_any` is particularly important, as it handles both standard Protobuf types and our custom JSON-encoded complex types. |
| `lib/snakepit/adapters/grpc_python.ex` | `Snakepit.Adapters.GRPCPython` | **The Stream Handler.** The `grpc_execute_stream` function is responsible for handling streaming calls. It receives a `Stream` object from `ClientImpl` and returns a processed stream that the caller (`Snakepit.Pool`) can consume. |

#### 4.2. Python Side

| File | Component | Role & Responsibilities |
| :--- | :--- | :--- |
| `grpc_server.py` | Python Server | **The Entry Point.** This script is executed by the `GRPCWorker`. It parses command-line arguments (like `--port` and `--adapter`), starts the `asyncio` event loop, and runs the gRPC server. |
| `grpc_server.py` | `BridgeServiceServicer` | **The RPC Endpoint.** This class implements all the RPC methods defined in the `.proto` file. It is stateless and acts as a dispatcher. |
| `grpc_server.py` | `ExecuteTool` / `ExecuteStreamingTool` | **The Core Logic.** These `async` methods handle incoming requests. They use `TypeSerializer.decode_any` to deserialize parameters, instantiate the specified Python adapter, `await` the adapter's `execute_tool` method, and then use `TypeValidator` and `TypeSerializer` to correctly encode the result before sending it back. |
| `snakepit_bridge/serialization.py` | `TypeSerializer` | **The Serializer/Deserializer.** Symmetrical to its Elixir counterpart. `encode_any` packs Python objects into `Any` messages, and `decode_any` unpacks them. |
| `snakepit_bridge/types.py` | `TypeValidator` | **The Type Oracle.** The `infer_type` class method inspects a Python object and returns its corresponding `VariableType` enum (e.g., `STRING`, `FLOAT`). It correctly infers that `dict` and `list` should be treated as `STRING`, triggering JSON encoding. |
| `snakepit_bridge/adapters/showcase_adapter.py` | `ShowcaseAdapter` | **The Business Logic.** An example adapter that implements the `execute_tool` method. This method contains the actual logic for tools like `ping`, `echo`, and the streaming `stream_progress`. For streaming tools, it returns a *synchronous generator*. |

---

### 5. Data Flow Walkthroughs

#### 5.1. Unary Call: `Snakepit.execute("ping", ...)`

1.  **Elixir App**: Calls `Snakepit.execute("ping", %{...})`.
2.  **Pool**: `Snakepit.Pool` receives the call, checks out an available `GRPCWorker`, and calls `GRPCWorker.execute(worker_id, "ping", ...)`.
3.  **Worker**: `Snakepit.GRPCWorker` receives the call and delegates to `Snakepit.Adapters.GRPCPython.grpc_execute(...)`.
4.  **Adapter**: The `GRPCPython` adapter calls `Snakepit.GRPC.Client.execute_tool(...)`.
5.  **Client**: `Snakepit.GRPC.Client` delegates to `Snakepit.GRPC.ClientImpl.execute_tool(...)`.
6.  **Encoding (ClientImpl)**:
    *   `infer_and_encode_any` is called on the arguments.
    *   `Types.infer_type` classifies them.
    *   `Serialization.encode_any` packs them into `Any` protobuf messages.
    *   An `ExecuteToolRequest` message is constructed.
7.  **RPC Call**: `BridgeService.Stub.execute_tool` sends the request over the network.
8.  **Server**: The Python `BridgeServiceServicer` receives the request in its `ExecuteTool` method.
9.  **Decoding (Server)**: `TypeSerializer.decode_any` is used to convert the `Any` parameters back into Python objects (e.g., strings, dicts).
10. **Adapter Call**: The server instantiates `ShowcaseAdapter` and calls `await adapter.execute_tool(tool_name="ping", ...)`.
11. **Execution**: The `ping` method in the adapter runs and returns a Python `dict`.
12. **Encoding (Server)**:
    *   `TypeValidator.infer_type` classifies the returned `dict` as `STRING`.
    *   `TypeSerializer.encode_any` JSON-encodes the `dict` and packs it into a `StringValue`, which is then wrapped in an `Any` message.
    *   An `ExecuteToolResponse` is constructed with the `Any` message in its `result` field.
13. **RPC Response**: The server returns the response over the network.
14. **Decoding (ClientImpl)**: `handle_tool_response` receives the response and calls `Serialization.decode_any` on the `result` field.
15. **Deserialization**: `Serialization.decode_any` sees the `StringValue` `type_url`, unpacks the JSON string, and uses `Jason.decode!` to convert it back into an Elixir map.
16. **Return**: The final Elixir map is returned all the way up the call stack to the original application code.

#### 5.2. Streaming Call: `Snakepit.execute_stream("stream_progress", ...)`

1.  **Steps 1-7**: Identical to the unary call, but `execute_stream` is called down the chain, ultimately reaching `Snakepit.GRPC.ClientImpl.execute_streaming_tool`.
2.  **RPC Call**: `ClientImpl` calls `BridgeService.Stub.execute_streaming_tool`, which returns an Elixir `Stream` struct representing the open RPC connection.
3.  **Server**: The Python `ExecuteStreamingTool` method receives the request.
4.  **Steps 9-11**: Identical to the unary call, but this time `adapter.execute_tool` returns a *generator object*.
5.  **Streaming (Server)**: The `ExecuteStreamingTool` method iterates over the generator. For each item yielded by the generator, it JSON-encodes it and `yield`s a `ToolChunk` protobuf message.
6.  **Stream Consumption (Elixir)**:
    *   The `GRPCPython` adapter receives the `Stream` struct from `ClientImpl`.
    *   It creates a new, processed stream that maps over the raw gRPC stream.
    *   For each `ToolChunk` received, it decodes the `data` bytes using `Jason.decode!` and calls the user-provided `callback_fn` as a side effect.
    *   It returns `{:ok, processed_stream}`.
7.  **Return**: The `GRPCWorker` and `Pool` pass this `{:ok, stream}` tuple back to the original `SnakepitShowcase.Demos.StreamingDemo` code.
8.  **Final Execution**: The demo code calls `Enum.each` on the returned stream, which lazily pulls chunks from the Python server until the stream is complete.

---

### 6. Developer Guide

#### 6.1. Running Demos and Tests
The primary validation tool is the showcase application.

```bash
# Navigate to the showcase directory
cd examples/snakepit_showcase

# Install dependencies
mix setup

# Run all demos in sequence
mix demo.all
```

#### 6.2. Debugging Tips
*   **Result is `nil` or `{}`**: This is almost always a **serialization mismatch**. The field name or type being sent by one side does not match what the other side expects based on the `.proto` file.
    *   **Checklist**:
        1.  Are you using `parameters` in the Elixir request and `request.parameters` in the Python server?
        2.  Are you setting the `result` field in the Python response?
        3.  Is the `TypeValidator` in Python correctly inferring the type? Add a `logger.info` call to check `var_type_str`.
*   **`MatchError` or `FunctionClauseError` in Elixir**: This usually means the data structure returned from Python, after being deserialized, does not match what the Elixir code expects. For example, the code expects a map but receives a string.
    *   **Debug**: `IO.inspect` the result of the `Snakepit.execute` call before the line that crashes. This will show you the actual deserialized data structure.
*   **Streaming Fails or Hangs**: Check the chain of return values: `GRPCPython` adapter -> `GRPCWorker` -> `Pool`. Ensure they are passing the stream object or expected tuple correctly. Also, verify that the Python adapter method is correctly `yield`ing results.

#### 6.3. Extending Functionality (Adding a New Tool)
1.  **Python**: Add a new method to the `snakepit_bridge/adapters/showcase_adapter.py`.
2.  **Elixir**: Simply call the new tool via `Snakepit.execute("your_new_tool_name", %{...})`. No Elixir code changes are needed in the bridge itself.

---
This documentation provides a complete picture of the gRPC bridge's design, implementation, and operational flow, enabling effective development and maintenance.
