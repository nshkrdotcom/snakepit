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
  alias Snakepit.Logger, as: SLog

  alias Snakepit.Bridge.InternalToolSpec

  @table_name :snakepit_tool_registry
  @max_tool_name_length 64
  @tool_name_pattern ~r/^[A-Za-z0-9][A-Za-z0-9_\-\.]*$/
  @max_metadata_entries 32
  @max_metadata_bytes 4_096
  @log_category :bridge

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

    SLog.info(@log_category, "ToolRegistry started with ETS table: #{@table_name}")

    {:ok, %{}}
  end

  @impl true
  def handle_call({:register_elixir_tool, session_id, tool_name, handler, metadata}, _from, state) do
    with {:ok, normalized_name} <- validate_tool_name(tool_name),
         {:ok, normalized_metadata} <- validate_metadata(metadata),
         :ok <- ensure_tool_not_registered(session_id, normalized_name) do
      tool_spec = %InternalToolSpec{
        name: normalized_name,
        type: :local,
        handler: handler,
        parameters: Map.get(normalized_metadata, :parameters, []),
        description: Map.get(normalized_metadata, :description, ""),
        metadata: normalized_metadata,
        exposed_to_python: Map.get(normalized_metadata, :exposed_to_python, false)
      }

      case :ets.insert_new(@table_name, {{session_id, normalized_name}, tool_spec}) do
        true ->
          SLog.debug(
            @log_category,
            "Registered Elixir tool: #{normalized_name} for session: #{session_id}"
          )

          {:reply, :ok, state}

        false ->
          {:reply, {:error, {:duplicate_tool, normalized_name}}, state}
      end
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(
        {:register_python_tool, session_id, tool_name, worker_id, metadata},
        _from,
        state
      ) do
    with {:ok, normalized_name} <- validate_tool_name(tool_name),
         {:ok, normalized_metadata} <- validate_metadata(metadata),
         :ok <- ensure_tool_not_registered(session_id, normalized_name) do
      tool_spec = %InternalToolSpec{
        name: normalized_name,
        type: :remote,
        worker_id: worker_id,
        parameters: Map.get(normalized_metadata, :parameters, []),
        description: Map.get(normalized_metadata, :description, ""),
        metadata: normalized_metadata
      }

      case :ets.insert_new(@table_name, {{session_id, normalized_name}, tool_spec}) do
        true ->
          SLog.debug(
            @log_category,
            "Registered Python tool: #{normalized_name} for session: #{session_id}"
          )

          {:reply, :ok, state}

        false ->
          {:reply, {:error, {:duplicate_tool, normalized_name}}, state}
      end
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:register_tools, session_id, tool_specs}, _from, state) do
    with {:ok, normalized_specs} <- build_remote_specs(tool_specs),
         :ok <- ensure_batch_not_registered(session_id, normalized_specs),
         {:ok, names} <- insert_tool_batch(session_id, normalized_specs) do
      SLog.info(@log_category, "Registered #{length(names)} tools for session: #{session_id}")
      {:reply, {:ok, names}, state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:cleanup_session, session_id}, _from, state) do
    pattern = {{session_id, :_}, :_}
    num_deleted = :ets.match_object(@table_name, pattern) |> length()
    :ets.match_delete(@table_name, pattern)

    SLog.debug(@log_category, "Cleaned up #{num_deleted} tools for session: #{session_id}")

    {:reply, :ok, state}
  end

  defp validate_tool_name(name) when is_binary(name) do
    trimmed = String.trim(name)

    cond do
      trimmed == "" ->
        {:error, {:invalid_tool_name, :empty}}

      byte_size(trimmed) > @max_tool_name_length ->
        {:error, {:invalid_tool_name, :too_long}}

      not Regex.match?(@tool_name_pattern, trimmed) ->
        {:error, {:invalid_tool_name, :invalid_format}}

      true ->
        {:ok, trimmed}
    end
  end

  defp validate_tool_name(_), do: {:error, {:invalid_tool_name, :invalid_type}}

  defp validate_metadata(nil), do: {:ok, %{}}
  defp validate_metadata(%{} = metadata), do: enforce_metadata_constraints(metadata)

  defp validate_metadata(metadata) when is_list(metadata) do
    metadata
    |> Enum.into(%{})
    |> enforce_metadata_constraints()
  rescue
    ArgumentError ->
      {:error, {:invalid_metadata, :duplicate_keys}}
  end

  defp validate_metadata(_), do: {:error, {:invalid_metadata, :unsupported_type}}

  defp enforce_metadata_constraints(metadata) do
    entry_count = map_size(metadata)

    cond do
      entry_count > @max_metadata_entries ->
        {:error, {:invalid_metadata, :too_many_entries}}

      byte_size(:erlang.term_to_binary(metadata)) > @max_metadata_bytes ->
        {:error, {:invalid_metadata, :too_large}}

      true ->
        {:ok, metadata}
    end
  end

  defp ensure_tool_not_registered(session_id, tool_name) do
    case :ets.lookup(@table_name, {session_id, tool_name}) do
      [] -> :ok
      _ -> {:error, {:duplicate_tool, tool_name}}
    end
  end

  defp build_remote_specs(tool_specs) do
    tool_specs
    |> Enum.reduce_while({:ok, [], MapSet.new()}, &accumulate_remote_spec/2)
    |> finalize_remote_specs()
  end

  defp accumulate_remote_spec(spec, {:ok, acc, names}) do
    with {:ok, tool_spec} <- build_remote_tool_spec(spec),
         :ok <- check_duplicate_name(tool_spec.name, names) do
      {:cont, {:ok, [tool_spec | acc], MapSet.put(names, tool_spec.name)}}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp check_duplicate_name(name, names) do
    if MapSet.member?(names, name) do
      {:error, {:duplicate_tool, name}}
    else
      :ok
    end
  end

  defp finalize_remote_specs({:ok, specs, _names}), do: {:ok, Enum.reverse(specs)}
  defp finalize_remote_specs({:error, reason}), do: {:error, reason}

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
         metadata: normalized_metadata
       }}
    else
      {:error, _} = error -> error
    end
  end

  defp ensure_batch_not_registered(session_id, specs) do
    Enum.reduce_while(specs, :ok, fn spec, :ok ->
      case :ets.lookup(@table_name, {session_id, spec.name}) do
        [] -> {:cont, :ok}
        _ -> {:halt, {:error, {:duplicate_tool, spec.name}}}
      end
    end)
  end

  defp insert_tool_batch(session_id, specs) do
    specs
    |> Enum.reduce_while({:ok, []}, &insert_tool_spec(session_id, &1, &2))
    |> finalize_tool_batch()
  end

  defp insert_tool_spec(session_id, spec, {:ok, inserted_names}) do
    case :ets.insert_new(@table_name, {{session_id, spec.name}, spec}) do
      true ->
        {:cont, {:ok, [spec.name | inserted_names]}}

      false ->
        rollback_inserted_tools(session_id, inserted_names)
        {:halt, {:error, {:duplicate_tool, spec.name}}}
    end
  end

  defp rollback_inserted_tools(session_id, inserted_names) do
    Enum.each(inserted_names, fn name ->
      :ets.delete(@table_name, {session_id, name})
    end)
  end

  defp finalize_tool_batch({:ok, names}), do: {:ok, Enum.reverse(names)}
  defp finalize_tool_batch({:error, reason}), do: {:error, reason}
end
