# How to Implement a `Snakepit.Adapter`

- **Date**: 2025-07-31
- **Status**: Final Draft

## 1. Introduction

This document is a hands-on, technical guide for Elixir developers who need to build a `Snakepit.Adapter`. An adapter is the bridge that connects the generic `snakepit` process engine to a specific runtime, such as a Python script running a gRPC server.

This guide assumes you have already read the [`Snakepit.Adapter` Behaviour: An Architectural Overview](./20250731_behaviour_interface_overview.md) and understand the core design principles. This document will walk you through building a complete, production-quality adapter for a Python gRPC worker.

## 2. The `Snakepit.Adapter` Behaviour Definition

This is the formal contract your adapter module must implement.

```elixir
defmodule Snakepit.Adapter do
  @moduledoc "The behaviour (interface) for a Snakepit worker adapter."
  @type handle :: any()
  @type adapter_state :: any()
  @callback init(config :: keyword()) :: {:ok, adapter_state} | {:error, any()}
  @callback start_worker(worker_id :: term(), adapter_state :: adapter_state) ::
              {:ok, os_pid :: pid(), handle} | {:error, any()}
  @callback execute(handle, command :: String.t(), args :: map()) ::
              {:ok, result :: any()} | {:error, any()}
  @callback terminate(handle, reason :: term()) :: :ok
end
```

---

## 3. A Complete gRPC Adapter Example

We will now build a complete adapter, `DSPex.Runtime.Py.Adapter`, that manages a Python gRPC worker.

### The Worker-Side: Python gRPC Server

First, let's look at the Python script our adapter will manage. This script starts a gRPC server on a random port and, crucially, **signals its readiness by printing a JSON line to STDOUT**.

`priv/python/grpc_worker.py`:
```python
import sys
import os
import json
import grpc
from concurrent import futures
# Assume pb2 files are generated and available
import snakepit_pb2
import snakepit_pb2_grpc

# The gRPC service implementation
class WorkerService(snakepit_pb2_grpc.WorkerServiceServicer):
    def Execute(self, request, context):
        # In a real app, do work based on request.command
        response_data = {"status": "ok", "input_args": request.args}
        return snakepit_pb2.ExecuteResponse(result=json.dumps(response_data))

def serve():
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=1))
    snakepit_pb2_grpc.add_WorkerServiceServicer_to_server(WorkerService(), server)

    # Bind to port 0 to let the OS choose a free port
    port = server.add_insecure_port('[::]:0')
    server.start()

    # CRITICAL: Signal readiness to the Elixir host
    # This is the non-negotiable part of the contract
    ready_signal = {"status": "ready", "port": port, "pid": os.getpid()}
    print(json.dumps(ready_signal), flush=True)

    server.wait_for_termination()

if __name__ == '__main__':
    serve()
```

### The Elixir Adapter Implementation

Now, let's build the Elixir adapter that will manage this Python script.

`lib/dspex_runtime_py/adapter.ex`:
```elixir
defmodule DSPex.Runtime.Py.Adapter do
  @behaviour Snakepit.Adapter

  # The handle will store the gRPC channel and the Port process
  defstruct handle(grpc_channel: nil, port_process: nil)

  # This state will hold the path to the python executable
  defstruct adapter_state(python_executable: nil)

  ###
  ### CALLBACK IMPLEMENTATIONS
  ###

  @impl Snakepit.Adapter
  def init(config) do
    # Find the python executable path from config, with a default
    python_executable = Keyword.get(config, :python_executable, "python3")
    state = %__MODULE__.adapter_state{python_executable: python_executable}
    {:ok, state}
  end

  @impl Snakepit.Adapter
  def start_worker(worker_id, adapter_state) do
    # Path to our worker script and wrapper
    script_path = "priv/python/grpc_worker.py"

    # Use Port to spawn the script, allowing us to read its STDOUT
    port_process = Port.open(
      {:spawn_executable, adapter_state.python_executable},
      [:binary, :exit_status, args: [script_path]]
    )
    os_pid = Port.info(port_process, :os_pid)

    # Wait for the {"status": "ready", "port": ...} signal
    case wait_for_ready_signal(port_process, 5000) do
      {:ok, ready_data} ->
        # The signal was received, connect the gRPC client
        port = ready_data["port"]
        grpc_address = "localhost:#{port}"

        case GRPC.Stub.connect(grpc_address) do
          {:ok, channel} ->
            handle = %__MODULE__.handle{
              grpc_channel: channel,
              port_process: port_process
            }
            # This is the moment of success!
            {:ok, os_pid, handle}

          {:error, reason} ->
            Port.close(port_process)
            {:error, {:grpc_connect_failed, reason}}
        end

      {:error, reason} ->
        # The worker failed to start in time or crashed
        Port.close(port_process)
        {:error, {:worker_start_failed, reason}}
    end
  end

  @impl Snakepit.Adapter
  def execute(handle, command, args) do
    # Use the gRPC channel from the handle to make the call
    request = Snakepit.Pb.ExecuteRequest.new(command: command, args: Jason.encode!(args))

    case Snakepit.Pb.WorkerService.Stub.execute(handle.grpc_channel, request) do
      {:ok, response} ->
        # The result from gRPC is a JSON string, decode it
        Jason.decode(response.result)

      {:error, reason} ->
        {:error, {:grpc_call_failed, reason}}
    end
  end

  @impl Snakepit.Adapter
  def terminate(handle, _reason) do
    # Gracefully clean up resources
    GRPC.Stub.disconnect(handle.grpc_channel)
    Port.close(handle.port_process)
    :ok
  end

  ###
  ### HELPER FUNCTIONS
  ###

  defp wait_for_ready_signal(port, timeout) do
    receive do
      {^port, {:data, {:binary, data}}} ->
        case Jason.decode(data) do
          {:ok, %{"status" => "ready"} = ready_data} ->
            {:ok, ready_data}
          _ ->
            # Some other STDOUT line, ignore and keep waiting
            wait_for_ready_signal(port, timeout)
        end
      {^port, {:exit_status, status}} ->
        {:error, {:exited, status}}
    after
      timeout ->
        {:error, :timeout}
    end
  end
end
```

This complete example demonstrates all the core principles of a robust adapter:
1.  It uses `Port` to spawn the worker and capture its `os_pid`.
2.  It waits for a deterministic JSON signal from the worker's `STDOUT`.
3.  It establishes the `gRPC` connection only *after* the worker has signaled it's ready.
4.  It stores the `gRPC` channel in the `handle` for use in `execute/3`.
5.  It cleans up all resources gracefully in `terminate/2`.
