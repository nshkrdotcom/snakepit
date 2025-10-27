defmodule Snakepit.Bridge.InternalToolSpec do
  @moduledoc """
  Internal specification for a tool in the registry.
  Separate from the protobuf ToolSpec to avoid conflicts.
  """

  defstruct name: nil,
            # :local or :remote
            type: nil,
            # Function reference for local tools
            handler: nil,
            # Worker ID for remote tools
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

defmodule Snakepit.Bridge.ToolRegistry do
  @moduledoc """
  Registry for managing tool metadata and execution.

  Maintains a registry of both local (Elixir) and remote (Python) tools,
  handles tool discovery, registration, and provides execution dispatch.
  """

  use GenServer
  require Logger
  alias Snakepit.Logger, as: SLog

  alias Snakepit.Bridge.InternalToolSpec

  @table_name :snakepit_tool_registry

  # Client API

  @doc """
  Starts the ToolRegistry GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a local Elixir tool.
  """
  def register_elixir_tool(session_id, tool_name, handler, metadata \\ %{}) do
    GenServer.call(__MODULE__, {:register_elixir_tool, session_id, tool_name, handler, metadata})
  end

  @doc """
  Registers a remote Python tool.
  """
  def register_python_tool(session_id, tool_name, worker_id, metadata \\ %{}) do
    GenServer.call(
      __MODULE__,
      {:register_python_tool, session_id, tool_name, worker_id, metadata}
    )
  end

  @doc """
  Registers multiple tools at once (used by Python workers on startup).
  """
  def register_tools(session_id, tool_specs) do
    GenServer.call(__MODULE__, {:register_tools, session_id, tool_specs})
  end

  @doc """
  Gets a specific tool by name.
  """
  def get_tool(session_id, tool_name) do
    case :ets.lookup(@table_name, {session_id, tool_name}) do
      [{_key, tool_spec}] -> {:ok, tool_spec}
      [] -> {:error, "Tool #{tool_name} not found for session #{session_id}"}
    end
  end

  @doc """
  Lists all tools available for a session.
  """
  def list_tools(session_id) do
    pattern = {{session_id, :_}, :_}
    tools = :ets.match_object(@table_name, pattern)

    Enum.map(tools, fn {{_session_id, _tool_name}, tool_spec} -> tool_spec end)
  end

  @doc """
  Lists only Elixir tools exposed to Python for a session.
  """
  def list_exposed_elixir_tools(session_id) do
    list_tools(session_id)
    |> Enum.filter(fn tool -> tool.type == :local && tool.exposed_to_python end)
  end

  @doc """
  Executes a local Elixir tool.
  """
  def execute_local_tool(session_id, tool_name, params) do
    with {:ok, tool} <- get_tool(session_id, tool_name),
         :local <- tool.type do
      try do
        result = apply(tool.handler, [params])
        {:ok, result}
      rescue
        e -> {:error, "Tool execution failed: #{inspect(e)}"}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, "Tool #{tool_name} is not a local tool"}
    end
  end

  @doc """
  Removes all tools for a session (cleanup).
  """
  def cleanup_session(session_id) do
    GenServer.call(__MODULE__, {:cleanup_session, session_id})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for fast lookups
    :ets.new(@table_name, [:named_table, :set, :protected, read_concurrency: true])

    SLog.info("ToolRegistry started with ETS table: #{@table_name}")

    {:ok, %{}}
  end

  @impl true
  def handle_call({:register_elixir_tool, session_id, tool_name, handler, metadata}, _from, state) do
    tool_spec = %InternalToolSpec{
      name: tool_name,
      type: :local,
      handler: handler,
      parameters: Map.get(metadata, :parameters, []),
      description: Map.get(metadata, :description, ""),
      metadata: metadata,
      exposed_to_python: Map.get(metadata, :exposed_to_python, false)
    }

    :ets.insert(@table_name, {{session_id, tool_name}, tool_spec})

    SLog.debug("Registered Elixir tool: #{tool_name} for session: #{session_id}")

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(
        {:register_python_tool, session_id, tool_name, worker_id, metadata},
        _from,
        state
      ) do
    tool_spec = %InternalToolSpec{
      name: tool_name,
      type: :remote,
      worker_id: worker_id,
      parameters: Map.get(metadata, :parameters, []),
      description: Map.get(metadata, :description, ""),
      metadata: metadata
    }

    :ets.insert(@table_name, {{session_id, tool_name}, tool_spec})

    SLog.debug("Registered Python tool: #{tool_name} for session: #{session_id}")

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:register_tools, session_id, tool_specs}, _from, state) do
    # Register multiple tools at once
    results =
      Enum.map(tool_specs, fn spec ->
        tool_spec = %InternalToolSpec{
          name: spec.name,
          type: :remote,
          worker_id: spec.worker_id,
          parameters: spec.parameters,
          description: spec.description,
          metadata: spec.metadata || %{}
        }

        :ets.insert(@table_name, {{session_id, spec.name}, tool_spec})
        spec.name
      end)

    SLog.info("Registered #{length(results)} tools for session: #{session_id}")

    {:reply, {:ok, results}, state}
  end

  @impl true
  def handle_call({:cleanup_session, session_id}, _from, state) do
    pattern = {{session_id, :_}, :_}
    num_deleted = :ets.match_delete(@table_name, pattern)

    SLog.debug("Cleaned up #{num_deleted} tools for session: #{session_id}")

    {:reply, :ok, state}
  end
end
