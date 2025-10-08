# Snakepit v0.5 Roadmap: ALTAR Integration

**Version:** Draft 1.0
**Date:** October 8, 2025
**Status:** Planning
**Target Release:** Q1 2026

---

## Executive Summary

Snakepit v0.5 represents a strategic evolution from a **generic Python bridge** to a full **LATER (Local Agent & Tool Execution Runtime) implementation** as defined by the ALTAR architecture. This release positions Snakepit as the canonical Python runtime for ALTAR's promotion path, enabling seamless transition from local development to distributed GRID deployment.

**Key Transformation:**
- **Current (v0.4.3):** Generic Python process pooler with gRPC, sessions, and tool registry
- **Target (v0.5):** ALTAR-compliant LATER runtime with ADM support and GRID-ready architecture

**Strategic Value:**
- Become the reference implementation for LATER's Python runtime
- Enable tool portability across the ALTAR ecosystem
- Provide frictionless on-ramp to GRID enterprise deployment
- Maintain backward compatibility while adding ALTAR capabilities

---

## Table of Contents

1. [Current State Analysis](#current-state-analysis)
2. [ALTAR Architecture Integration](#altar-architecture-integration)
3. [Core Features for v0.5](#core-features-for-v05)
4. [Implementation Phases](#implementation-phases)
5. [Technical Design](#technical-design)
6. [Migration Strategy](#migration-strategy)
7. [Timeline and Milestones](#timeline-and-milestones)
8. [Success Metrics](#success-metrics)

---

## Current State Analysis

### What Snakepit Has (v0.4.3)

✅ **Strong Foundation for LATER:**

1. **Tool Registry System**
   - Python `@tool` decorator for declaring functions
   - Automatic schema generation from Python signatures
   - Session-scoped tool availability
   - Tool discovery and introspection
   - **Gap:** Not ADM-compliant schemas

2. **Session Management**
   - ETS-based session storage with TTL
   - Worker affinity per session
   - Session variables with constraints
   - Automatic cleanup
   - **Gap:** Not aligned with LATER's two-tier registry model

3. **gRPC Bridge**
   - High-performance HTTP/2 communication
   - Streaming support for long operations
   - Health checks and monitoring
   - Binary serialization for large data
   - **Gap:** Not mTLS-ready for GRID

4. **Process Management**
   - DETS-based process tracking
   - Orphan cleanup and crash recovery
   - Concurrent initialization
   - **Gap:** No GRID Host integration

5. **Variable System**
   - Type-safe variables (string, integer, float, boolean, tensor, embedding)
   - Constraint validation
   - Batch operations
   - **Gap:** Not integrated with ADM tool parameters

### What's Missing for LATER Compliance

❌ **ALTAR-Specific Requirements:**

1. **ADM (ALTAR Data Model) Support**
   - FunctionDeclaration schema format (OpenAPI 3.0-style)
   - FunctionCall and ToolResult structures
   - Schema validation against ADM spec
   - Canonical JSON serialization

2. **Two-Tier Registry Architecture**
   - Global Tool Definition Registry (application-wide)
   - Session-Scoped Registry (per-conversation)
   - Clean separation between definition and availability

3. **GRID Preparation**
   - mTLS support for secure communication
   - RBAC-ready authentication hooks
   - Audit logging hooks for enterprise compliance
   - Runtime announcement protocol

4. **Framework Adapters**
   - LangChain tool import/export
   - Semantic Kernel integration
   - Pydantic-AI compatibility (bidirectional)

5. **Enhanced Introspection**
   - `deftool`-style macro for Python decorators
   - Automatic parameter description extraction
   - Docstring parsing (Google/NumPy/Sphinx formats)
   - Type hint to ADM type mapping

---

## ALTAR Architecture Integration

### Where Snakepit Fits in ALTAR

```
┌─────────────────────────────────────────────────────────┐
│              ALTAR Ecosystem                            │
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │  Layer 3: GRID (Distributed Runtime)            │   │
│  │  - Host-Runtime separation                      │   │
│  │  - gRPC/mTLS communication                      │   │
│  │  - RBAC, audit logging, policy engine          │   │
│  │  - Multi-language runtime support               │   │
│  └────────────────────┬────────────────────────────┘   │
│                       │                                  │
│                Promotes to                              │
│                       ↓                                  │
│  ┌─────────────────────────────────────────────────┐   │
│  │  Layer 2: LATER (Local Runtime)                 │   │
│  │  ┌─────────────────────────────────────────┐    │   │
│  │  │ 🐍 Snakepit v0.5 - Python LATER Runtime │    │   │
│  │  │ - ADM FunctionDeclaration support       │    │   │
│  │  │ - Two-tier registry                     │    │   │
│  │  │ - Framework adapters (LangChain, etc.)  │    │   │
│  │  │ - Local execution, global registry      │    │   │
│  │  └─────────────────────────────────────────┘    │   │
│  │                                                  │   │
│  │  Other LATER Runtimes:                          │   │
│  │  - TypeScript LATER (Node.js tools)             │   │
│  │  - Go LATER (compiled performance tools)        │   │
│  │  - Elixir LATER (BEAM ecosystem tools)          │   │
│  └─────────────────────────────────────────────────┘   │
│                       ↑                                  │
│                Implements                               │
│                       ↓                                  │
│  ┌─────────────────────────────────────────────────┐   │
│  │  Layer 1: ADM (Universal Data Model)            │   │
│  │  - FunctionDeclaration, FunctionCall, Schema    │   │
│  │  - JSON serialization                           │   │
│  │  - Language-neutral contracts                   │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

### Snakepit's Role in the Promotion Path

**Development (LATER):**
```elixir
# Developer uses Snakepit v0.5 locally
config :my_app,
  tool_executor: {:later, Snakepit.LATER.Executor}

# Tools are registered in Snakepit's global registry
Snakepit.register_tool(weather_tool_declaration, &MyTools.get_weather/1)

# Execute locally during development
{:ok, result} = Snakepit.execute_tool(session_id, function_call)
```

**Production (GRID):**
```elixir
# Same tool definitions, different executor
config :my_app,
  tool_executor: {:grid, MyApp.GRIDHost, [
    host: "grid.production.com",
    port: 8080,
    mtls_cert: "/etc/certs/client.pem"
  ]}

# Snakepit now acts as a GRID Runtime
# Tools registered with Snakepit are announced to GRID Host
# Execution happens remotely with full enterprise security

# Application code remains identical
{:ok, result} = MyApp.ToolExecutor.execute_tool(session_id, function_call)
```

### Key ALTAR Concepts for Snakepit

1. **ADM FunctionDeclaration**
   ```python
   # Python tool with @tool decorator
   @tool(description="Gets weather for a location")
   def get_weather(location: str, unit: str = "celsius") -> dict:
       """
       Fetches current weather data.

       Args:
           location: City name or coordinates
           unit: Temperature unit (celsius or fahrenheit)
       """
       return weather_api.fetch(location, unit)

   # Automatically generates ADM FunctionDeclaration:
   {
     "name": "get_weather",
     "description": "Gets weather for a location",
     "parameters": {
       "type": "OBJECT",
       "properties": {
         "location": {
           "type": "STRING",
           "description": "City name or coordinates"
         },
         "unit": {
           "type": "STRING",
           "description": "Temperature unit (celsius or fahrenheit)",
           "enum": ["celsius", "fahrenheit"]
         }
       },
       "required": ["location"]
     }
   }
   ```

2. **Two-Tier Registry**
   - **Global Registry:** All tool definitions loaded at startup
   - **Session Registry:** Which tools are active for a specific conversation
   - **Security:** Session-level access control, not just global

3. **GRID Runtime Protocol**
   - **Announce:** Runtime tells Host what language/capabilities it supports
   - **Fulfill:** Runtime claims it can execute specific tool contracts
   - **Execute:** Host sends FunctionCall, Runtime returns ToolResult
   - **Stream:** Long-running operations with progressive results

---

## Core Features for v0.5

### Feature 1: ADM Compliance Layer

**Objective:** All Snakepit tools emit ADM-compliant schemas

**Implementation:**

1. **Schema Generator Module**
   ```elixir
   defmodule Snakepit.ALTAR.SchemaGenerator do
     @moduledoc """
     Converts Python type hints to ADM SchemaType.
     Implements ALTAR Data Model v1.0 spec.
     """

     @type adm_type :: :STRING | :INTEGER | :NUMBER | :BOOLEAN | :ARRAY | :OBJECT

     @spec python_type_to_adm(type_hint :: String.t()) :: adm_type()
     def python_type_to_adm("str"), do: :STRING
     def python_type_to_adm("int"), do: :INTEGER
     def python_type_to_adm("float"), do: :NUMBER
     def python_type_to_adm("bool"), do: :BOOLEAN
     def python_type_to_adm("list"), do: :ARRAY
     def python_type_to_adm("dict"), do: :OBJECT

     @spec generate_function_declaration(tool :: map()) :: {:ok, map()} | {:error, String.t()}
     def generate_function_declaration(tool) do
       # Convert Python tool info to ADM FunctionDeclaration
       %{
         "name" => tool.name,
         "description" => tool.description,
         "parameters" => %{
           "type" => "OBJECT",
           "properties" => build_properties(tool.signature),
           "required" => extract_required_params(tool.signature)
         }
       }
     end
   end
   ```

2. **Python Bridge Updates**
   ```python
   # snakepit_bridge/altar/adm.py
   from typing import get_type_hints, get_args, get_origin
   import inspect

   class ADMSchemaGenerator:
       """Generates ADM-compliant schemas from Python functions."""

       TYPE_MAPPING = {
           str: "STRING",
           int: "INTEGER",
           float: "NUMBER",
           bool: "BOOLEAN",
           list: "ARRAY",
           dict: "OBJECT"
       }

       @classmethod
       def from_function(cls, func) -> dict:
           """Extract ADM FunctionDeclaration from Python function."""
           sig = inspect.signature(func)
           hints = get_type_hints(func)
           doc = inspect.getdoc(func) or ""

           # Parse docstring for parameter descriptions
           param_docs = cls._parse_docstring(doc)

           properties = {}
           required = []

           for param_name, param in sig.parameters.items():
               if param_name == 'self' or param_name == 'ctx':
                   continue

               param_type = hints.get(param_name, str)
               adm_type = cls._map_type(param_type)

               properties[param_name] = {
                   "type": adm_type,
                   "description": param_docs.get(param_name, "")
               }

               # Handle enums from Literal types
               if hasattr(param.annotation, '__origin__'):
                   if param.annotation.__origin__ is Literal:
                       properties[param_name]["enum"] = list(get_args(param.annotation))

               # Check if required (no default value)
               if param.default == inspect.Parameter.empty:
                   required.append(param_name)

           return {
               "name": func.__name__,
               "description": cls._extract_summary(doc),
               "parameters": {
                   "type": "OBJECT",
                   "properties": properties,
                   "required": required
               }
           }
   ```

3. **Validation Module**
   ```elixir
   defmodule Snakepit.ALTAR.Validator do
     @moduledoc """
     Validates FunctionCall arguments against ADM schemas.
     Implements validation logic from ALTAR spec.
     """

     @spec validate_args(schema :: map(), args :: map()) ::
       :ok | {:error, String.t()}
     def validate_args(schema, args) do
       with :ok <- validate_required_fields(schema, args),
            :ok <- validate_types(schema, args),
            :ok <- validate_constraints(schema, args) do
         :ok
       end
     end

     defp validate_types(%{"properties" => props}, args) do
       Enum.reduce_while(props, :ok, fn {name, prop_schema}, _acc ->
         case Map.get(args, name) do
           nil -> {:cont, :ok}  # Optional field
           value ->
             case check_type(value, prop_schema["type"]) do
               :ok -> {:cont, :ok}
               {:error, reason} -> {:halt, {:error, "#{name}: #{reason}"}}
             end
         end
       end)
     end
   end
   ```

**Deliverables:**
- [ ] `Snakepit.ALTAR.SchemaGenerator` module
- [ ] Python `ADMSchemaGenerator` class
- [ ] `Snakepit.ALTAR.Validator` module
- [ ] Unit tests for all ADM type mappings
- [ ] Integration tests with real tool schemas

### Feature 2: Two-Tier Registry Architecture

**Objective:** Implement LATER's global + session registry pattern

**Current State:**
```elixir
# v0.4.3: Tool discovery happens at runtime
{:ok, tools} = Snakepit.Bridge.ToolRegistry.list_tools(session_id)
# Tools are registered per-session in Python
```

**Target State:**
```elixir
# v0.5: Global registry populated at startup
# Global Registry (application-wide, immutable at runtime)
:ok = Snakepit.LATER.GlobalRegistry.register_tool(
  function_declaration,  # ADM-compliant
  &MyTools.implementation/1
)

# Session Registry (ephemeral, per-conversation)
{:ok, session} = Snakepit.LATER.SessionRegistry.create_session(
  "user_123",
  allowed_tools: ["get_weather", "search_database"]
)

# Execution validates against both registries
{:ok, result} = Snakepit.LATER.Executor.execute_tool(
  "user_123",
  %FunctionCall{name: "get_weather", args: %{"location" => "Paris"}}
)
```

**Implementation:**

1. **Global Registry (GenServer)**
   ```elixir
   defmodule Snakepit.LATER.GlobalRegistry do
     use GenServer

     @moduledoc """
     Application-wide registry of tool definitions.
     Populated at startup, immutable during runtime.
     """

     # Client API

     def start_link(opts) do
       GenServer.start_link(__MODULE__, opts, name: __MODULE__)
     end

     @spec register_tool(declaration :: map(), impl :: function()) :: :ok | {:error, term()}
     def register_tool(declaration, implementation) do
       GenServer.call(__MODULE__, {:register, declaration, implementation})
     end

     @spec lookup_declaration(tool_name :: String.t()) ::
       {:ok, map()} | {:error, :not_found}
     def lookup_declaration(tool_name) do
       GenServer.call(__MODULE__, {:lookup_declaration, tool_name})
     end

     @spec lookup_implementation(tool_name :: String.t()) ::
       {:ok, function()} | {:error, :not_found}
     def lookup_implementation(tool_name) do
       GenServer.call(__MODULE__, {:lookup_impl, tool_name})
     end

     @spec list_all_tools() :: [map()]
     def list_all_tools do
       GenServer.call(__MODULE__, :list_all)
     end

     # Server Callbacks

     @impl true
     def init(_opts) do
       # ETS table for fast lookups
       table = :ets.new(:snakepit_global_tools, [
         :set,
         :protected,
         :named_table,
         read_concurrency: true
       ])

       {:ok, %{table: table}}
     end

     @impl true
     def handle_call({:register, declaration, impl}, _from, state) do
       tool_name = declaration["name"]

       # Validate declaration is ADM-compliant
       case Snakepit.ALTAR.Validator.validate_declaration(declaration) do
         :ok ->
           # Store both declaration and implementation
           :ets.insert(:snakepit_global_tools, {
             tool_name,
             %{declaration: declaration, implementation: impl}
           })
           {:reply, :ok, state}

         {:error, reason} ->
           {:reply, {:error, reason}, state}
       end
     end

     @impl true
     def handle_call({:lookup_declaration, tool_name}, _from, state) do
       case :ets.lookup(:snakepit_global_tools, tool_name) do
         [{^tool_name, %{declaration: decl}}] -> {:reply, {:ok, decl}, state}
         [] -> {:reply, {:error, :not_found}, state}
       end
     end
   end
   ```

2. **Session Registry (GenServer per session)**
   ```elixir
   defmodule Snakepit.LATER.SessionRegistry do
     use GenServer

     @moduledoc """
     Per-conversation registry managing which tools are active.
     Created when session starts, destroyed on session end.
     """

     # Client API

     @spec create_session(session_id :: String.t(), opts :: keyword()) ::
       {:ok, pid()} | {:error, term()}
     def create_session(session_id, opts \\ []) do
       allowed_tools = Keyword.get(opts, :allowed_tools, :all)
       ttl = Keyword.get(opts, :ttl, 3600)

       DynamicSupervisor.start_child(
         Snakepit.LATER.SessionSupervisor,
         {__MODULE__, session_id: session_id, allowed_tools: allowed_tools, ttl: ttl}
       )
     end

     @spec is_tool_available?(session_id :: String.t(), tool_name :: String.t()) :: boolean()
     def is_tool_available?(session_id, tool_name) do
       case Registry.lookup(Snakepit.SessionRegistry, session_id) do
         [{pid, _}] -> GenServer.call(pid, {:check_tool, tool_name})
         [] -> false
       end
     end

     @spec get_available_tools(session_id :: String.t()) :: [String.t()]
     def get_available_tools(session_id) do
       case Registry.lookup(Snakepit.SessionRegistry, session_id) do
         [{pid, _}] -> GenServer.call(pid, :list_tools)
         [] -> []
       end
     end

     # Server Implementation

     @impl true
     def init(opts) do
       session_id = Keyword.fetch!(opts, :session_id)
       allowed_tools = Keyword.fetch!(opts, :allowed_tools)
       ttl = Keyword.fetch!(opts, :ttl)

       # Register in session registry
       {:ok, _} = Registry.register(Snakepit.SessionRegistry, session_id, %{})

       # Build tool availability set
       tools = case allowed_tools do
         :all ->
           # All tools from global registry
           Snakepit.LATER.GlobalRegistry.list_all_tools()
           |> Enum.map(& &1["name"])
           |> MapSet.new()

         list when is_list(list) ->
           # Validate all tools exist in global registry
           Enum.reduce_while(list, MapSet.new(), fn tool_name, acc ->
             case Snakepit.LATER.GlobalRegistry.lookup_declaration(tool_name) do
               {:ok, _} -> {:cont, MapSet.put(acc, tool_name)}
               {:error, :not_found} ->
                 {:halt, {:error, "Tool not found: #{tool_name}"}}
             end
           end)
       end

       # Schedule TTL cleanup
       Process.send_after(self(), :expire, ttl * 1000)

       {:ok, %{
         session_id: session_id,
         tools: tools,
         created_at: DateTime.utc_now(),
         ttl: ttl
       }}
     end

     @impl true
     def handle_call({:check_tool, tool_name}, _from, state) do
       available = MapSet.member?(state.tools, tool_name)
       {:reply, available, state}
     end

     @impl true
     def handle_info(:expire, state) do
       # Session expired, shutdown
       {:stop, :normal, state}
     end
   end
   ```

3. **Unified Executor**
   ```elixir
   defmodule Snakepit.LATER.Executor do
     @moduledoc """
     Executes tool calls with validation against both registries.
     Implements LATER execution flow from spec.
     """

     @spec execute_tool(session_id :: String.t(), function_call :: map()) ::
       {:ok, map()} | {:error, term()}
     def execute_tool(session_id, %{"name" => tool_name, "args" => args} = function_call) do
       with {:ok, :available} <- check_session_availability(session_id, tool_name),
            {:ok, declaration} <- Snakepit.LATER.GlobalRegistry.lookup_declaration(tool_name),
            :ok <- Snakepit.ALTAR.Validator.validate_args(declaration["parameters"], args),
            {:ok, impl} <- Snakepit.LATER.GlobalRegistry.lookup_implementation(tool_name),
            {:ok, result} <- invoke_implementation(impl, args) do

         # Return ADM ToolResult
         {:ok, %{
           "call_id" => function_call["call_id"],
           "name" => tool_name,
           "content" => result,
           "is_error" => false
         }}
       else
         {:error, :tool_not_available} ->
           {:error, build_error_result(function_call, "Tool not available in session")}

         {:error, :not_found} ->
           {:error, build_error_result(function_call, "Tool not found in global registry")}

         {:error, validation_error} ->
           {:error, build_error_result(function_call, "Validation failed: #{validation_error}")}

         {:error, runtime_error} ->
           {:error, build_error_result(function_call, "Execution failed: #{inspect(runtime_error)}")}
       end
     end

     defp check_session_availability(session_id, tool_name) do
       if Snakepit.LATER.SessionRegistry.is_tool_available?(session_id, tool_name) do
         {:ok, :available}
       else
         {:error, :tool_not_available}
       end
     end

     defp invoke_implementation(impl, args) when is_function(impl, 1) do
       # Call Python implementation via gRPC worker
       {:ok, impl.(args)}
     rescue
       e -> {:error, Exception.message(e)}
     end
   end
   ```

**Deliverables:**
- [ ] `Snakepit.LATER.GlobalRegistry` GenServer
- [ ] `Snakepit.LATER.SessionRegistry` per-session GenServer
- [ ] `Snakepit.LATER.SessionSupervisor` for session lifecycle
- [ ] `Snakepit.LATER.Executor` with dual registry validation
- [ ] Migration guide from v0.4.3 tool system
- [ ] Integration tests for registry patterns

### Feature 3: GRID Preparation

**Objective:** Make Snakepit ready to act as a GRID Runtime

**GRID Runtime Responsibilities:**
1. **Announce capabilities** to GRID Host
2. **Fulfill tool contracts** defined by Host
3. **Execute tools** when Host sends FunctionCall
4. **Stream results** for long-running operations
5. **Secure communication** via mTLS

**Implementation:**

1. **Runtime Announcement Protocol**
   ```elixir
   defmodule Snakepit.GRID.RuntimeClient do
     @moduledoc """
     Connects to GRID Host and announces Snakepit as a Python runtime.
     Implements GRID Architecture runtime protocol.
     """

     use GenServer

     defstruct [
       :host_address,
       :runtime_id,
       :mtls_config,
       :connection,
       :announced_tools,
       :session_mappings
     ]

     # Client API

     def start_link(opts) do
       GenServer.start_link(__MODULE__, opts, name: __MODULE__)
     end

     @spec announce_to_host(host_address :: String.t(), mtls_config :: map()) ::
       :ok | {:error, term()}
     def announce_to_host(host_address, mtls_config \\ %{}) do
       GenServer.call(__MODULE__, {:announce, host_address, mtls_config})
     end

     @spec fulfill_tools(session_id :: String.t(), tool_names :: [String.t()]) ::
       :ok | {:error, term()}
     def fulfill_tools(session_id, tool_names) do
       GenServer.call(__MODULE__, {:fulfill, session_id, tool_names})
     end

     # Server Implementation

     @impl true
     def init(opts) do
       runtime_id = Keyword.get(opts, :runtime_id, generate_runtime_id())

       state = %__MODULE__{
         runtime_id: runtime_id,
         announced_tools: MapSet.new(),
         session_mappings: %{}
       }

       {:ok, state}
     end

     @impl true
     def handle_call({:announce, host_address, mtls_config}, _from, state) do
       # Connect to GRID Host via gRPC with mTLS
       case establish_connection(host_address, mtls_config) do
         {:ok, connection} ->
           # Send AnnounceRuntime message
           announcement = %{
             "runtime_id" => state.runtime_id,
             "language" => "python",
             "version" => snakepit_version(),
             "capabilities" => ["streaming", "binary_data", "health_checks"],
             "metadata" => %{
               "snakepit_version" => snakepit_version(),
               "python_version" => get_python_version(),
               "grpc_version" => get_grpc_version()
             }
           }

           case send_announcement(connection, announcement) do
             :ok ->
               new_state = %{state |
                 host_address: host_address,
                 mtls_config: mtls_config,
                 connection: connection
               }
               {:reply, :ok, new_state}

             {:error, reason} ->
               {:reply, {:error, reason}, state}
           end

         {:error, reason} ->
           {:reply, {:error, "Failed to connect to GRID Host: #{reason}"}, state}
       end
     end

     @impl true
     def handle_call({:fulfill, session_id, tool_names}, _from, state) do
       # Validate all tools exist in global registry
       case validate_tools_exist(tool_names) do
         :ok ->
           # Send FulfillTools message to Host
           fulfillment = %{
             "session_id" => session_id,
             "tool_names" => tool_names,
             "runtime_id" => state.runtime_id
           }

           case send_fulfillment(state.connection, fulfillment) do
             :ok ->
               # Track which tools we've committed to fulfill
               new_announced = Enum.reduce(tool_names, state.announced_tools, fn name, acc ->
                 MapSet.put(acc, name)
               end)

               new_mappings = Map.put(state.session_mappings, session_id, tool_names)

               new_state = %{state |
                 announced_tools: new_announced,
                 session_mappings: new_mappings
               }

               {:reply, :ok, new_state}

             {:error, reason} ->
               {:reply, {:error, reason}, state}
           end

         {:error, missing_tools} ->
           {:reply, {:error, "Tools not found in global registry: #{inspect(missing_tools)}"}, state}
       end
     end

     # Receives ToolCall from GRID Host
     @impl true
     def handle_info({:grid_tool_call, %{"invocation_id" => inv_id, "call" => function_call} = msg}, state) do
       session_id = msg["session_id"]

       # Execute via LATER Executor
       case Snakepit.LATER.Executor.execute_tool(session_id, function_call) do
         {:ok, tool_result} ->
           # Send ToolResult back to Host
           response = %{
             "invocation_id" => inv_id,
             "correlation_id" => msg["correlation_id"],
             "result" => tool_result
           }
           send_tool_result(state.connection, response)

         {:error, error_result} ->
           # Send error ToolResult
           error_response = %{
             "invocation_id" => inv_id,
             "correlation_id" => msg["correlation_id"],
             "result" => error_result
           }
           send_tool_result(state.connection, error_response)
       end

       {:noreply, state}
     end

     defp establish_connection(host_address, mtls_config) do
       # TODO: Implement mTLS connection setup
       # For now, regular gRPC connection
       {:ok, %{host: host_address}}
     end
   end
   ```

2. **mTLS Support**
   ```elixir
   defmodule Snakepit.GRID.MTLSConfig do
     @moduledoc """
     Manages mTLS certificates for secure GRID communication.
     Implements TLS 1.3+ requirement from AESP spec.
     """

     defstruct [
       :client_cert_path,
       :client_key_path,
       :ca_cert_path,
       :verify_mode,
       :ciphers
     ]

     @spec from_config(config :: map()) :: {:ok, t()} | {:error, term()}
     def from_config(config) do
       with {:ok, client_cert} <- read_cert(config["client_cert_path"]),
            {:ok, client_key} <- read_key(config["client_key_path"]),
            {:ok, ca_cert} <- read_cert(config["ca_cert_path"]) do

         {:ok, %__MODULE__{
           client_cert_path: config["client_cert_path"],
           client_key_path: config["client_key_path"],
           ca_cert_path: config["ca_cert_path"],
           verify_mode: :verify_peer,
           ciphers: tls13_ciphers()
         }}
       end
     end

     defp tls13_ciphers do
       # TLS 1.3 cipher suites for AESP compliance
       [
         "TLS_AES_256_GCM_SHA384",
         "TLS_AES_128_GCM_SHA256",
         "TLS_CHACHA20_POLY1305_SHA256"
       ]
     end
   end
   ```

3. **Audit Logging Hooks**
   ```elixir
   defmodule Snakepit.GRID.AuditLogger do
     @moduledoc """
     Provides audit logging hooks for GRID/AESP compliance.
     Logs all tool invocations, security events, and errors.
     """

     @type audit_event :: %{
       event_type: atom(),
       timestamp: DateTime.t(),
       session_id: String.t(),
       tool_name: String.t(),
       principal_id: String.t() | nil,
       tenant_id: String.t() | nil,
       result: :success | :failure,
       metadata: map()
     }

     @spec log_tool_invocation(
       session_id :: String.t(),
       tool_name :: String.t(),
       args :: map(),
       result :: {:ok, term()} | {:error, term()},
       metadata :: map()
     ) :: :ok
     def log_tool_invocation(session_id, tool_name, args, result, metadata \\ %{}) do
       event = %{
         event_type: :tool_invocation,
         timestamp: DateTime.utc_now(),
         session_id: session_id,
         tool_name: tool_name,
         principal_id: metadata[:principal_id],
         tenant_id: metadata[:tenant_id],
         result: if(match?({:ok, _}, result), do: :success, else: :failure),
         metadata: %{
           args_hash: hash_sensitive_data(args),
           execution_time_ms: metadata[:execution_time_ms],
           worker_id: metadata[:worker_id]
         }
       }

       emit_audit_event(event)
     end

     defp emit_audit_event(event) do
       # Send to configured audit backend (file, database, external service)
       :telemetry.execute(
         [:snakepit, :audit, :event],
         %{timestamp: event.timestamp},
         event
       )

       :ok
     end
   end
   ```

**Deliverables:**
- [ ] `Snakepit.GRID.RuntimeClient` for Host communication
- [ ] `Snakepit.GRID.MTLSConfig` for secure connections
- [ ] `Snakepit.GRID.AuditLogger` with AESP hooks
- [ ] Configuration system for GRID mode
- [ ] Integration tests with mock GRID Host

### Feature 4: Framework Adapters

**Objective:** Import/export tools from popular AI frameworks

**Supported Frameworks:**
1. **LangChain** (Priority 1 - most popular)
2. **Pydantic-AI** (Priority 2 - modern, growing)
3. **Semantic Kernel** (Priority 3 - C#/.NET bridge)

**Implementation:**

1. **LangChain Adapter**
   ```python
   # snakepit_bridge/altar/adapters/langchain.py
   from langchain_core.tools import BaseTool
   from snakepit_bridge.altar.adm import ADMSchemaGenerator
   from snakepit_bridge.core import tool

   class LangChainAdapter:
       """Bidirectional adapter for LangChain tools."""

       @staticmethod
       def import_tool(lc_tool: BaseTool) -> dict:
           """Convert LangChain tool to ADM FunctionDeclaration."""
           # Map Pydantic schema to ADM schema
           adm_schema = _convert_pydantic_to_adm(lc_tool.args_schema)

           declaration = {
               "name": lc_tool.name,
               "description": lc_tool.description,
               "parameters": adm_schema
           }

           # Create wrapper that calls LangChain tool
           @tool(name=lc_tool.name, description=lc_tool.description)
           def wrapper(**kwargs):
               return lc_tool.invoke(kwargs)

           return declaration, wrapper

       @staticmethod
       def export_tool(tool_name: str, declaration: dict):
           """Expose Snakepit tool as LangChain BaseTool."""
           from pydantic import create_model, BaseModel

           # Convert ADM schema to Pydantic model
           fields = {}
           for param_name, param_schema in declaration["parameters"]["properties"].items():
               py_type = _adm_to_python_type(param_schema["type"])
               default = ... if param_name in declaration["parameters"]["required"] else None
               fields[param_name] = (py_type, default)

           ArgsModel = create_model(f"{tool_name}Args", **fields)

           class SnakepitTool(BaseTool):
               name: str = tool_name
               description: str = declaration["description"]
               args_schema: type[BaseModel] = ArgsModel

               def _run(self, **kwargs):
                   # Call back to Snakepit
                   from snakepit_bridge.context import get_current_context
                   ctx = get_current_context()
                   return ctx.execute_tool(tool_name, kwargs)

           return SnakepitTool()
   ```

2. **Pydantic-AI Adapter**
   ```python
   # snakepit_bridge/altar/adapters/pydantic_ai.py
   from pydantic_ai import Agent
   from snakepit_bridge.core import tool

   class PydanticAIAdapter:
       """Bidirectional adapter for Pydantic-AI."""

       @staticmethod
       def import_agent_tools(agent: Agent) -> list[tuple[dict, callable]]:
           """Import all tools from a Pydantic-AI agent."""
           imported = []

           for tool_func in agent.tools:
               # Extract schema from Pydantic-AI tool
               declaration = ADMSchemaGenerator.from_function(tool_func)
               imported.append((declaration, tool_func))

           return imported

       @staticmethod
       def export_to_agent(tool_declarations: list[dict]) -> list[callable]:
           """Create Pydantic-AI compatible tools from ADM declarations."""
           tools = []

           for decl in tool_declarations:
               # Create function that calls Snakepit
               def tool_wrapper(**kwargs):
                   from snakepit_bridge.context import get_current_context
                   ctx = get_current_context()
                   return ctx.execute_tool(decl["name"], kwargs)

               tool_wrapper.__name__ = decl["name"]
               tool_wrapper.__doc__ = decl["description"]

               tools.append(tool_wrapper)

           return tools
   ```

3. **Elixir Integration API**
   ```elixir
   defmodule Snakepit.ALTAR.Adapters.LangChain do
     @moduledoc """
     Import tools from LangChain into Snakepit.
     """

     @spec import_tool(tool_name :: String.t(), opts :: keyword()) ::
       {:ok, map()} | {:error, term()}
     def import_tool(tool_name, opts \\ []) do
       session_id = Keyword.get(opts, :session_id, generate_session_id())

       # Call Python adapter to import LangChain tool
       result = Snakepit.execute_in_session(session_id, "import_langchain_tool", %{
         "tool_name" => tool_name
       })

       case result do
         {:ok, %{"declaration" => declaration}} ->
           # Register in Snakepit's global registry
           impl = fn args ->
             Snakepit.execute_in_session(session_id, "execute_langchain_tool", %{
               "tool_name" => tool_name,
               "args" => args
             })
           end

           Snakepit.LATER.GlobalRegistry.register_tool(declaration, impl)

         {:error, reason} ->
           {:error, reason}
       end
     end

     @spec import_all_from_module(module_path :: String.t()) ::
       {:ok, [map()]} | {:error, term()}
     def import_all_from_module(module_path) do
       # Discover all LangChain tools in a Python module
       # Import them all into Snakepit
     end
   end
   ```

**Deliverables:**
- [ ] `LangChainAdapter` Python class (import/export)
- [ ] `PydanticAIAdapter` Python class (import/export)
- [ ] `Snakepit.ALTAR.Adapters.LangChain` Elixir module
- [ ] `Snakepit.ALTAR.Adapters.PydanticAI` Elixir module
- [ ] Documentation with examples for each adapter
- [ ] Integration tests with real LangChain/Pydantic-AI tools

### Feature 5: Enhanced Tool Introspection

**Objective:** Match or exceed Pydantic-AI's developer ergonomics

**Python Side:**
```python
# snakepit_bridge/core.py (enhanced)
from typing import get_type_hints, Literal
import inspect
from docstring_parser import parse as parse_docstring

def tool(
    name: str | None = None,
    description: str | None = None,
    schema: dict | None = None
):
    """
    Decorator for registering Python functions as ALTAR-compliant tools.

    Features:
    - Automatic schema generation from type hints
    - Docstring parsing (Google, NumPy, Sphinx formats)
    - Parameter description extraction
    - Enum constraint detection from Literal types
    - Default value handling
    """
    def decorator(func):
        # Auto-generate schema if not provided
        if schema is None:
            tool_schema = ADMSchemaGenerator.from_function(func)
        else:
            tool_schema = schema

        # Use function name if name not provided
        tool_name = name or func.__name__

        # Use first line of docstring if description not provided
        tool_description = description
        if tool_description is None:
            parsed_doc = parse_docstring(inspect.getdoc(func) or "")
            tool_description = parsed_doc.short_description or ""

        # Store metadata on function
        func._snakepit_tool = {
            "name": tool_name,
            "description": tool_description,
            "schema": tool_schema,
            "original_function": func
        }

        # Auto-register with global registry
        from snakepit_bridge.registry import global_registry
        global_registry.register(tool_name, tool_schema, func)

        return func

    return decorator

# Example usage with full introspection
@tool(description="Searches Wikipedia for information")
def search_wikipedia(
    query: str,
    language: Literal["en", "es", "fr"] = "en",
    max_results: int = 5
) -> dict:
    """
    Search Wikipedia articles.

    Args:
        query: The search query string
        language: Wikipedia language edition to search
        max_results: Maximum number of results to return

    Returns:
        Dictionary with search results
    """
    # Implementation
    pass

# Generated schema (automatic):
{
    "name": "search_wikipedia",
    "description": "Searches Wikipedia for information",
    "parameters": {
        "type": "OBJECT",
        "properties": {
            "query": {
                "type": "STRING",
                "description": "The search query string"
            },
            "language": {
                "type": "STRING",
                "description": "Wikipedia language edition to search",
                "enum": ["en", "es", "fr"]
            },
            "max_results": {
                "type": "INTEGER",
                "description": "Maximum number of results to return"
            }
        },
        "required": ["query"]
    }
}
```

**Elixir Macro (Future):**
```elixir
# Possible future enhancement - Elixir-native tool definition
defmodule MyApp.Tools do
  use Snakepit.ALTAR.Tools

  # Future: deftool macro that compiles to Python @tool functions
  deftool search_database(query, filters \\ %{}) do
    @description "Searches the application database"
    @param query, :string, "Search query", required: true
    @param filters, :map, "Optional filters"

    # Implementation delegates to Python
    database_search(query, filters)
  end
end
```

**Deliverables:**
- [ ] Enhanced `@tool` decorator with full introspection
- [ ] `docstring_parser` integration for all formats
- [ ] Automatic enum detection from `Literal` types
- [ ] Default value handling
- [ ] Documentation with examples
- [ ] Comparison guide: Pydantic-AI vs Snakepit introspection

---

## Implementation Phases

### Phase 1: ADM Foundation (4 weeks)

**Goal:** Core ALTAR Data Model support

**Week 1-2: Schema Layer**
- [ ] Implement `Snakepit.ALTAR.SchemaGenerator`
- [ ] Implement Python `ADMSchemaGenerator`
- [ ] Type mapping (Python → ADM)
- [ ] Unit tests for all type mappings

**Week 3: Validation Layer**
- [ ] Implement `Snakepit.ALTAR.Validator`
- [ ] Parameter validation logic
- [ ] Constraint validation (enums, ranges)
- [ ] Error message formatting

**Week 4: Integration**
- [ ] Update `@tool` decorator to emit ADM schemas
- [ ] Update gRPC protocol to transport ADM structures
- [ ] Integration tests
- [ ] Documentation

**Deliverables:**
- Working ADM schema generation
- Validation against ADM spec
- All tests passing
- Migration guide for existing tools

### Phase 2: Two-Tier Registry (3 weeks)

**Goal:** LATER-compliant registry architecture

**Week 1: Global Registry**
- [ ] Implement `Snakepit.LATER.GlobalRegistry` GenServer
- [ ] ETS-backed storage
- [ ] Registration API
- [ ] Lookup APIs

**Week 2: Session Registry**
- [ ] Implement `Snakepit.LATER.SessionRegistry`
- [ ] Session lifecycle management
- [ ] Tool availability checking
- [ ] TTL and cleanup

**Week 3: Unified Executor**
- [ ] Implement `Snakepit.LATER.Executor`
- [ ] Dual registry validation
- [ ] Integration with existing gRPC bridge
- [ ] Migration from v0.4.3 patterns

**Deliverables:**
- Two-tier registry operational
- All existing examples migrated
- Performance benchmarks
- Documentation

### Phase 3: GRID Preparation (4 weeks)

**Goal:** Ready to connect to GRID Host

**Week 1-2: Runtime Client**
- [ ] Implement `Snakepit.GRID.RuntimeClient`
- [ ] Announcement protocol
- [ ] Fulfillment protocol
- [ ] Tool call handling

**Week 3: Security**
- [ ] mTLS configuration
- [ ] Certificate management
- [ ] Secure connection setup
- [ ] Authentication hooks

**Week 4: Audit & Observability**
- [ ] Audit logging system
- [ ] RBAC hooks (preparation)
- [ ] Telemetry events
- [ ] Integration tests with mock Host

**Deliverables:**
- GRID Runtime mode operational
- mTLS working
- Audit logs generating
- Documentation for GRID deployment

### Phase 4: Framework Adapters (4 weeks)

**Goal:** Interoperability with AI ecosystem

**Week 1-2: LangChain Adapter**
- [ ] Import LangChain tools
- [ ] Export to LangChain
- [ ] Bidirectional examples
- [ ] Tests with real LangChain tools

**Week 3: Pydantic-AI Adapter**
- [ ] Import Pydantic-AI tools
- [ ] Export to Pydantic-AI
- [ ] Integration examples
- [ ] Tests

**Week 4: Documentation & Polish**
- [ ] Comprehensive adapter documentation
- [ ] Migration guides
- [ ] Example applications
- [ ] Performance benchmarks

**Deliverables:**
- LangChain adapter working
- Pydantic-AI adapter working
- Documentation and examples
- All tests passing

### Phase 5: Polish & Release (2 weeks)

**Goal:** Production-ready v0.5 release

**Week 1: Testing & Documentation**
- [ ] Comprehensive integration test suite
- [ ] Performance benchmarking
- [ ] Documentation review
- [ ] Migration guide completion
- [ ] Changelog

**Week 2: Release**
- [ ] Beta release (v0.5.0-beta.1)
- [ ] Gather feedback
- [ ] Bug fixes
- [ ] Final release (v0.5.0)

**Deliverables:**
- Snakepit v0.5.0 released
- Complete documentation
- Migration guide
- Example applications

---

## Technical Design

### Directory Structure

```
snakepit/
├── lib/
│   ├── snakepit/
│   │   ├── altar/              # NEW: ALTAR integration
│   │   │   ├── schema_generator.ex
│   │   │   ├── validator.ex
│   │   │   ├── adapters/
│   │   │   │   ├── langchain.ex
│   │   │   │   └── pydantic_ai.ex
│   │   │   └── types.ex
│   │   ├── later/              # NEW: LATER implementation
│   │   │   ├── global_registry.ex
│   │   │   ├── session_registry.ex
│   │   │   ├── session_supervisor.ex
│   │   │   └── executor.ex
│   │   ├── grid/               # NEW: GRID integration
│   │   │   ├── runtime_client.ex
│   │   │   ├── mtls_config.ex
│   │   │   └── audit_logger.ex
│   │   ├── bridge/             # Existing
│   │   ├── pool/               # Existing
│   │   └── ...
│   └── snakepit.ex
├── priv/
│   └── python/
│       ├── snakepit_bridge/
│       │   ├── altar/          # NEW: ALTAR Python support
│       │   │   ├── adm.py
│       │   │   ├── adapters/
│       │   │   │   ├── langchain.py
│       │   │   │   └── pydantic_ai.py
│       │   │   └── introspection.py
│       │   ├── core.py         # Enhanced @tool decorator
│       │   ├── registry.py     # Global registry
│       │   └── ...
│       └── ...
├── docs/
│   ├── altar/                  # NEW: ALTAR documentation
│   │   ├── adm_integration.md
│   │   ├── later_compliance.md
│   │   ├── grid_runtime.md
│   │   └── framework_adapters.md
│   └── ...
└── examples/
    └── altar/                  # NEW: ALTAR examples
        ├── basic_later_usage.exs
        ├── grid_runtime_demo.exs
        ├── langchain_import.exs
        └── pydantic_ai_export.exs
```

### Configuration

```elixir
# config/config.exs

config :snakepit,
  # Execution mode: :later (local) or :grid (distributed)
  execution_mode: :later,

  # LATER configuration
  later: [
    # Auto-load tools at startup
    auto_register_tools: true,
    # Path to tool definitions
    tool_manifest_path: "priv/tools/manifest.json"
  ],

  # GRID configuration (when execution_mode: :grid)
  grid: [
    host_address: "grid.production.com:8080",
    runtime_id: "snakepit-python-001",
    mtls: [
      client_cert: "/etc/certs/snakepit-client.pem",
      client_key: "/etc/certs/snakepit-client-key.pem",
      ca_cert: "/etc/certs/ca.pem"
    ],
    announce_on_start: true
  ],

  # Framework adapters
  adapters: [
    langchain: [enabled: true],
    pydantic_ai: [enabled: true],
    semantic_kernel: [enabled: false]
  ]
```

### API Examples

**LATER Mode (Development):**
```elixir
# Application startup - tools are registered globally
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Start Snakepit in LATER mode
      {Snakepit.LATER.Supervisor, []},
      # Other children...
    ]

    # Register tools at startup
    register_application_tools()

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  defp register_application_tools do
    # Python tools are auto-discovered from @tool decorators
    # Optionally import from frameworks:
    Snakepit.ALTAR.Adapters.LangChain.import_all_from_module("my_app.langchain_tools")
  end
end

# Usage in application code
defmodule MyApp.AgentController do
  def handle_user_query(user_id, query) do
    # Create session for this conversation
    {:ok, session} = Snakepit.LATER.SessionRegistry.create_session(
      "user_#{user_id}",
      allowed_tools: ["search_wikipedia", "calculator", "get_weather"]
    )

    # LLM decides to use a tool
    function_call = %{
      "call_id" => UUID.generate(),
      "name" => "search_wikipedia",
      "args" => %{"query" => query}
    }

    # Execute via LATER
    {:ok, result} = Snakepit.LATER.Executor.execute_tool(
      "user_#{user_id}",
      function_call
    )

    # Use result in LLM response
    result
  end
end
```

**GRID Mode (Production):**
```elixir
# config/prod.exs
config :snakepit,
  execution_mode: :grid,
  grid: [
    host_address: System.get_env("GRID_HOST_ADDRESS"),
    runtime_id: System.get_env("RUNTIME_ID"),
    mtls: [
      client_cert: System.get_env("MTLS_CLIENT_CERT"),
      client_key: System.get_env("MTLS_CLIENT_KEY"),
      ca_cert: System.get_env("MTLS_CA_CERT")
    ]
  ]

# Application code DOES NOT CHANGE
defmodule MyApp.AgentController do
  def handle_user_query(user_id, query) do
    # Same API as LATER mode!
    {:ok, session} = Snakepit.LATER.SessionRegistry.create_session(
      "user_#{user_id}",
      allowed_tools: ["search_wikipedia", "calculator", "get_weather"]
    )

    function_call = %{
      "call_id" => UUID.generate(),
      "name" => "search_wikipedia",
      "args" => %{"query" => query}
    }

    # Now executes via GRID Host (transparently)
    {:ok, result} = Snakepit.LATER.Executor.execute_tool(
      "user_#{user_id}",
      function_call
    )

    result
  end
end
```

---

## Migration Strategy

### From v0.4.3 to v0.5

**Breaking Changes:**
- Tool registry API changed (global vs session)
- Tool schemas must be ADM-compliant
- `Snakepit.execute/2` deprecated in favor of `Snakepit.LATER.Executor.execute_tool/2`

**Migration Steps:**

1. **Update Tool Decorators**
   ```python
   # v0.4.3
   @tool
   def my_tool(arg1, arg2):
       pass

   # v0.5 (no change needed - automatic upgrade)
   @tool
   def my_tool(arg1: str, arg2: int) -> dict:
       """Tool description."""
       pass
   ```

2. **Update Tool Registration**
   ```elixir
   # v0.4.3
   Snakepit.Bridge.ToolRegistry.register_tool(session_id, tool_name, handler)

   # v0.5
   Snakepit.LATER.GlobalRegistry.register_tool(declaration, implementation)
   Snakepit.LATER.SessionRegistry.create_session(session_id, allowed_tools: [tool_name])
   ```

3. **Update Execution Calls**
   ```elixir
   # v0.4.3
   {:ok, result} = Snakepit.execute_in_session(session_id, "tool_name", args)

   # v0.5
   function_call = %{"call_id" => id, "name" => "tool_name", "args" => args}
   {:ok, result} = Snakepit.LATER.Executor.execute_tool(session_id, function_call)
   ```

**Compatibility Layer:**
We will provide a compatibility shim for 1 minor release (v0.5.x) that allows v0.4.3 code to work with deprecation warnings.

---

## Timeline and Milestones

### Q4 2025 (October - December)

**Milestone 1: ADM Foundation (Oct 15 - Nov 15)**
- ADM schema generation working
- Validation layer complete
- Integration tests passing
- Documentation published

**Milestone 2: Two-Tier Registry (Nov 15 - Dec 6)**
- Global and Session registries operational
- Unified Executor working
- v0.4.3 examples migrated
- Performance benchmarks

**Milestone 3: GRID Preparation (Dec 6 - Jan 3)**
- Runtime client connecting to mock Host
- mTLS configuration working
- Audit logging operational

### Q1 2026 (January - March)

**Milestone 4: Framework Adapters (Jan 3 - Jan 31)**
- LangChain adapter complete
- Pydantic-AI adapter complete
- Documentation and examples

**Milestone 5: Beta Release (Feb 1 - Feb 14)**
- v0.5.0-beta.1 released
- Community testing
- Bug fixes

**Milestone 6: Final Release (Feb 15 - Mar 1)**
- v0.5.0 released to Hex
- Documentation complete
- Migration guide published
- Blog post and announcement

---

## Success Metrics

### Technical Metrics

1. **ADM Compliance:** 100% of tool schemas pass ADM validation
2. **Performance:** No regression from v0.4.3 (maintain 1400-1500 ops/sec)
3. **Test Coverage:** >90% for new ALTAR modules
4. **Documentation:** All public APIs documented with examples

### Adoption Metrics

1. **Migration:** 90% of v0.4.3 users successfully migrate within 3 months
2. **Framework Integration:** At least 10 public examples using LangChain/Pydantic-AI adapters
3. **GRID Readiness:** Snakepit successfully connects to ALTAR GRID reference implementation

### Community Metrics

1. **GitHub Stars:** +100 stars within 3 months of release
2. **Issues:** <10 critical bugs reported in first month
3. **Feedback:** Positive sentiment from DSPex and ALTAR communities

---

## Risk Mitigation

### Risk 1: ALTAR Spec Changes

**Risk:** ALTAR specs may evolve during implementation
**Mitigation:**
- Stay in close contact with ALTAR maintainers
- Design with abstraction layers for easy spec updates
- Version compatibility in mind

### Risk 2: Performance Regression

**Risk:** ADM validation overhead slows execution
**Mitigation:**
- Benchmark continuously
- Cache validation results
- Optimize hot paths

### Risk 3: Breaking Changes Impact

**Risk:** v0.5 breaks existing DSPex/user code
**Mitigation:**
- Comprehensive migration guide
- Compatibility shim for v0.4.3 API
- Early beta release for community testing
- Clear deprecation warnings

### Risk 4: GRID Complexity

**Risk:** Full GRID integration too complex for v0.5
**Mitigation:**
- Make GRID features optional
- Phased approach (LATER first, GRID readiness second)
- Mock Host for testing without full GRID

---

## Appendix A: ALTAR Terminology

- **ADM (ALTAR Data Model):** Language-agnostic data structures for tool contracts
- **LATER (Local Agent & Tool Execution Runtime):** Local, in-process execution pattern
- **GRID (Global Runtime & Interop Director):** Distributed, secure runtime architecture
- **FunctionDeclaration:** ADM structure defining a tool's schema
- **FunctionCall:** ADM structure for invoking a tool
- **ToolResult:** ADM structure for tool execution results
- **AESP (ALTAR Enterprise Security Profile):** Enterprise-grade security controls for GRID

---

## Appendix B: References

- [ALTAR Data Model Specification](https://github.com/nshkrdotcom/ALTAR/blob/main/priv/docs/specs/01-data-model/data-model.md)
- [LATER Implementation Pattern](https://github.com/nshkrdotcom/ALTAR/blob/main/priv/docs/specs/02-later-impl/later-impl.md)
- [GRID Architecture](https://github.com/nshkrdotcom/ALTAR/blob/main/priv/docs/specs/03-grid-arch/grid-arch.md)
- [AESP Specification](https://github.com/nshkrdotcom/ALTAR/blob/main/priv/docs/specs/03-grid-arch/aesp.md)
- [Pydantic-AI ALTAR Gap Analysis](https://github.com/nshkrdotcom/ALTAR/blob/main/docs/pydantic_ai_altar_gap_analysis.md)

---

**End of Roadmap**
