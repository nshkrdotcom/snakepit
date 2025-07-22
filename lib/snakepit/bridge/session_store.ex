defmodule Snakepit.Bridge.SessionStore do
  @moduledoc """
  Centralized session store using ETS for high-performance session management.

  This GenServer manages a centralized ETS table for storing session data,
  providing CRUD operations, TTL-based expiration, and automatic cleanup.
  The store is designed for high concurrency with optimized ETS settings.
  """

  use GenServer
  require Logger

  alias Snakepit.Bridge.Session
  alias Snakepit.Bridge.Variables.{Variable, Types}

  @default_table_name :snakepit_sessions
  # 1 minute
  @cleanup_interval 60_000
  # 1 hour
  @default_ttl 3600

  ## Client API

  @doc """
  Starts the SessionStore GenServer.

  ## Options

  - `:name` - The name to register the GenServer (default: __MODULE__)
  - `:table_name` - The ETS table name (default: :snakepit_sessions)
  - `:cleanup_interval` - Cleanup interval in milliseconds (default: 60_000)
  - `:default_ttl` - Default TTL for sessions in seconds (default: 3600)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Creates a new session with the given ID and options.

  ## Parameters

  - `session_id` - Unique session identifier
  - `opts` - Keyword list of options passed to Session.new/2

  ## Returns

  `{:ok, session}` if successful, `{:error, reason}` if failed.

  ## Examples

      {:ok, session} = SessionStore.create_session("session_123")
      {:ok, session} = SessionStore.create_session("session_456", ttl: 7200)
  """
  @spec create_session(String.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def create_session(session_id, opts \\ []) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:create_session, session_id, opts})
  end

  @spec create_session(GenServer.server(), String.t(), keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def create_session(server, session_id, opts) when is_binary(session_id) do
    GenServer.call(server, {:create_session, session_id, opts})
  end

  @doc """
  Gets a session by ID, automatically updating the last_accessed timestamp.

  ## Parameters

  - `session_id` - The session identifier

  ## Returns

  `{:ok, session}` if found, `{:error, :not_found}` if not found.
  """
  @spec get_session(String.t()) :: {:ok, Session.t()} | {:error, :not_found}
  def get_session(session_id) when is_binary(session_id) do
    get_session(__MODULE__, session_id)
  end

  @spec get_session(GenServer.server(), String.t()) :: {:ok, Session.t()} | {:error, :not_found}
  def get_session(server, session_id) when is_binary(session_id) do
    GenServer.call(server, {:get_session, session_id})
  end

  @doc """
  Updates a session using the provided update function.

  The update function receives the current session and should return
  the updated session. The operation is atomic.

  ## Parameters

  - `session_id` - The session identifier
  - `update_fn` - Function that takes a session and returns an updated session

  ## Returns

  `{:ok, updated_session}` if successful, `{:error, reason}` if failed.

  ## Examples

      {:ok, session} = SessionStore.update_session("session_123", fn session ->
        Session.put_program(session, "prog_1", %{data: "example"})
      end)
  """
  @spec update_session(String.t(), (Session.t() -> Session.t())) ::
          {:ok, Session.t()} | {:error, term()}
  def update_session(session_id, update_fn)
      when is_binary(session_id) and is_function(update_fn, 1) do
    update_session(__MODULE__, session_id, update_fn)
  end

  @spec update_session(GenServer.server(), String.t(), (Session.t() -> Session.t())) ::
          {:ok, Session.t()} | {:error, term()}
  def update_session(server, session_id, update_fn)
      when is_binary(session_id) and is_function(update_fn, 1) do
    GenServer.call(server, {:update_session, session_id, update_fn})
  end

  @doc """
  Deletes a session by ID.

  ## Parameters

  - `session_id` - The session identifier

  ## Returns

  `:ok` always (idempotent operation).
  """
  @spec delete_session(String.t()) :: :ok
  def delete_session(session_id) when is_binary(session_id) do
    delete_session(__MODULE__, session_id)
  end

  @spec delete_session(GenServer.server(), String.t()) :: :ok
  def delete_session(server, session_id) when is_binary(session_id) do
    GenServer.call(server, {:delete_session, session_id})
  end

  @doc """
  Manually triggers cleanup of expired sessions.

  ## Returns

  The number of sessions that were cleaned up.
  """
  @spec cleanup_expired_sessions() :: non_neg_integer()
  def cleanup_expired_sessions do
    cleanup_expired_sessions(__MODULE__)
  end

  @spec cleanup_expired_sessions(GenServer.server()) :: non_neg_integer()
  def cleanup_expired_sessions(server) do
    GenServer.call(server, :cleanup_expired_sessions)
  end

  @doc """
  Gets statistics about the session store.

  ## Returns

  A map containing various statistics about the session store.
  """
  @spec get_stats() :: map()
  def get_stats do
    get_stats(__MODULE__)
  end

  @spec get_stats(GenServer.server()) :: map()
  def get_stats(server) do
    GenServer.call(server, :get_stats)
  end

  @doc """
  Lists all active session IDs.

  ## Returns

  A list of all active session IDs.
  """
  @spec list_sessions() :: [String.t()]
  def list_sessions do
    list_sessions(__MODULE__)
  end

  @spec list_sessions(GenServer.server()) :: [String.t()]
  def list_sessions(server) do
    GenServer.call(server, :list_sessions)
  end

  @doc """
  Checks if a session exists.

  ## Parameters

  - `session_id` - The session identifier

  ## Returns

  `true` if the session exists, `false` otherwise.
  """
  @spec session_exists?(String.t()) :: boolean()
  def session_exists?(session_id) when is_binary(session_id) do
    session_exists?(__MODULE__, session_id)
  end

  @spec session_exists?(GenServer.server(), String.t()) :: boolean()
  def session_exists?(server, session_id) when is_binary(session_id) do
    GenServer.call(server, {:session_exists, session_id})
  end

  ## Global Program Storage API

  @doc """
  Stores a program globally, accessible to any worker.

  This is used for anonymous operations where programs need to be
  accessible across different pool workers.

  ## Parameters

  - `program_id` - Unique program identifier
  - `program_data` - Program data to store

  ## Returns

  `:ok` if successful, `{:error, reason}` if failed.
  """
  @spec store_global_program(String.t(), map()) :: :ok | {:error, term()}
  def store_global_program(program_id, program_data) when is_binary(program_id) do
    store_global_program(__MODULE__, program_id, program_data)
  end

  @spec store_global_program(GenServer.server(), String.t(), map()) :: :ok | {:error, term()}
  def store_global_program(server, program_id, program_data) when is_binary(program_id) do
    GenServer.call(server, {:store_global_program, program_id, program_data})
  end

  @doc """
  Retrieves a globally stored program.

  ## Parameters

  - `program_id` - The program identifier

  ## Returns

  `{:ok, program_data}` if found, `{:error, :not_found}` if not found.
  """
  @spec get_global_program(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_global_program(program_id) when is_binary(program_id) do
    get_global_program(__MODULE__, program_id)
  end

  @spec get_global_program(GenServer.server(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_global_program(server, program_id) when is_binary(program_id) do
    GenServer.call(server, {:get_global_program, program_id})
  end

  @doc """
  Deletes a globally stored program.

  ## Parameters

  - `program_id` - The program identifier

  ## Returns

  `:ok` always (idempotent operation).
  """
  @spec delete_global_program(String.t()) :: :ok
  def delete_global_program(program_id) when is_binary(program_id) do
    delete_global_program(__MODULE__, program_id)
  end

  @spec delete_global_program(GenServer.server(), String.t()) :: :ok
  def delete_global_program(server, program_id) when is_binary(program_id) do
    GenServer.call(server, {:delete_global_program, program_id})
  end

  ## Variable API

  @doc """
  Registers a new variable in a session.

  ## Options
    * `:constraints` - Type-specific constraints
    * `:metadata` - Additional metadata
    * `:description` - Human-readable description

  ## Examples

      iex> SessionStore.register_variable("session_1", :temperature, :float, 0.7,
      ...>   constraints: %{min: 0.0, max: 2.0},
      ...>   description: "LLM generation temperature"
      ...> )
      {:ok, "var_temperature_1234567"}
  """
  @spec register_variable(String.t(), atom() | String.t(), atom(), any(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def register_variable(session_id, name, type, initial_value, opts \\ []) do
    GenServer.call(__MODULE__, {:register_variable, session_id, name, type, initial_value, opts})
  end

  @doc """
  Gets a variable by ID or name.

  Supports both string and atom identifiers. Names are resolved
  through the session's variable index.
  """
  @spec get_variable(String.t(), String.t() | atom()) ::
          {:ok, Variable.t()} | {:error, term()}
  def get_variable(session_id, identifier) do
    GenServer.call(__MODULE__, {:get_variable, session_id, identifier})
  end

  @doc """
  Gets a variable's current value directly.

  Convenience function that returns just the value.
  """
  @spec get_variable_value(String.t(), String.t() | atom(), any()) :: any()
  def get_variable_value(session_id, identifier, default \\ nil) do
    case get_variable(session_id, identifier) do
      {:ok, variable} -> variable.value
      {:error, _} -> default
    end
  end

  @doc """
  Updates a variable's value with validation.

  The variable's type constraints are enforced and version
  is automatically incremented.
  """
  @spec update_variable(String.t(), String.t() | atom(), any(), map()) ::
          :ok | {:error, term()}
  def update_variable(session_id, identifier, new_value, metadata \\ %{}) do
    GenServer.call(__MODULE__, {:update_variable, session_id, identifier, new_value, metadata})
  end

  @doc """
  Lists all variables in a session.

  Returns variables sorted by creation time (oldest first).
  """
  @spec list_variables(String.t()) :: {:ok, [Variable.t()]} | {:error, term()}
  def list_variables(session_id) do
    GenServer.call(__MODULE__, {:list_variables, session_id})
  end

  @doc """
  Lists variables matching a pattern.

  Supports wildcards: "temp_*" matches "temp_1", "temp_2", etc.
  """
  @spec list_variables(String.t(), String.t()) :: {:ok, [Variable.t()]} | {:error, term()}
  def list_variables(session_id, pattern) do
    GenServer.call(__MODULE__, {:list_variables, session_id, pattern})
  end

  @doc """
  Deletes a variable from the session.
  """
  @spec delete_variable(String.t(), String.t() | atom()) :: :ok | {:error, term()}
  def delete_variable(session_id, identifier) do
    GenServer.call(__MODULE__, {:delete_variable, session_id, identifier})
  end

  @doc """
  Checks if a variable exists.
  """
  @spec has_variable?(String.t(), String.t() | atom()) :: boolean()
  def has_variable?(session_id, identifier) do
    case get_variable(session_id, identifier) do
      {:ok, _} -> true
      _ -> false
    end
  end

  ## Batch Operations

  @doc """
  Gets multiple variables efficiently.

  Returns a map of identifier => variable for found variables
  and a list of missing identifiers.
  """
  @spec get_variables(String.t(), [String.t() | atom()]) ::
          {:ok, %{found: map(), missing: [String.t()]}} | {:error, term()}
  def get_variables(session_id, identifiers) do
    GenServer.call(__MODULE__, {:get_variables, session_id, identifiers})
  end

  @doc """
  Updates multiple variables.

  ## Options
    * `:atomic` - If true, all updates must succeed or none are applied
    * `:metadata` - Metadata to apply to all updates

  Returns a map of identifier => :ok | {:error, reason}
  """
  @spec update_variables(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def update_variables(session_id, updates, opts \\ []) do
    GenServer.call(__MODULE__, {:update_variables, session_id, updates, opts})
  end

  @doc """
  Exports all variables from a session.

  Used for session migration in Stage 4.
  """
  @spec export_variables(String.t()) :: {:ok, [map()]} | {:error, term()}
  def export_variables(session_id) do
    with {:ok, variables} <- list_variables(session_id) do
      exported = Enum.map(variables, &Variable.to_map/1)
      {:ok, exported}
    end
  end

  @doc """
  Imports variables into a session.

  Used for session restoration in Stage 4.
  """
  @spec import_variables(String.t(), [map()]) :: {:ok, integer()} | {:error, term()}
  def import_variables(session_id, variable_maps) do
    GenServer.call(__MODULE__, {:import_variables, session_id, variable_maps})
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    # Get table name from options or use default
    table_name = Keyword.get(opts, :table_name, @default_table_name)

    # Create ETS table with optimized concurrency settings
    table =
      :ets.new(table_name, [
        :set,
        :public,
        :named_table,
        {:read_concurrency, true},
        {:write_concurrency, true},
        {:decentralized_counters, true}
      ])

    # Create global programs table
    global_programs_table_name = :"#{table_name}_global_programs"

    global_programs_table =
      :ets.new(global_programs_table_name, [
        :set,
        :public,
        :named_table,
        {:read_concurrency, true},
        {:write_concurrency, true},
        {:decentralized_counters, true}
      ])

    cleanup_interval = Keyword.get(opts, :cleanup_interval, @cleanup_interval)
    default_ttl = Keyword.get(opts, :default_ttl, @default_ttl)
    # 1 hour default
    global_program_ttl = Keyword.get(opts, :global_program_ttl, 3600)

    # Schedule periodic cleanup
    Process.send_after(self(), :cleanup_expired_sessions, cleanup_interval)

    state = %{
      table: table,
      table_name: table_name,
      global_programs_table: global_programs_table,
      global_programs_table_name: global_programs_table_name,
      cleanup_interval: cleanup_interval,
      default_ttl: default_ttl,
      global_program_ttl: global_program_ttl,
      stats: %{
        sessions_created: 0,
        sessions_deleted: 0,
        sessions_expired: 0,
        cleanup_runs: 0,
        global_programs_stored: 0,
        global_programs_deleted: 0,
        global_programs_expired: 0
      }
    }

    Logger.info(
      "SessionStore started with table #{table} and global programs table #{global_programs_table}"
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:create_session, session_id, opts}, _from, state) do
    case :ets.lookup(state.table, session_id) do
      [{^session_id, _existing_session}] ->
        {:reply, {:error, :already_exists}, state}

      [] ->
        # Set default TTL if not provided
        opts = Keyword.put_new(opts, :ttl, state.default_ttl)
        session = Session.new(session_id, opts)

        case Session.validate(session) do
          :ok ->
            # Store as {session_id, {last_accessed, ttl, session}} for efficient cleanup
            ets_record = {session_id, {session.last_accessed, session.ttl, session}}
            :ets.insert(state.table, ets_record)
            new_stats = Map.update(state.stats, :sessions_created, 1, &(&1 + 1))
            {:reply, {:ok, session}, %{state | stats: new_stats}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:update_session, session_id, update_fn}, _from, state) do
    case :ets.lookup(state.table, session_id) do
      [{^session_id, {_last_accessed, _ttl, session}}] ->
        try do
          updated_session = update_fn.(session)

          case Session.validate(updated_session) do
            :ok ->
              # Touch the session to update last_accessed
              touched_session = Session.touch(updated_session)
              # Store as {session_id, {last_accessed, ttl, session}} for efficient cleanup
              ets_record =
                {session_id,
                 {touched_session.last_accessed, touched_session.ttl, touched_session}}

              :ets.insert(state.table, ets_record)
              {:reply, {:ok, touched_session}, state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        rescue
          error ->
            Logger.error("Error updating session #{session_id}: #{inspect(error)}")
            {:reply, {:error, {:update_failed, error}}, state}
        end

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:cleanup_expired_sessions, _from, state) do
    {expired_count, new_stats} = do_cleanup_expired_sessions(state.table, state.stats)
    {:reply, expired_count, %{state | stats: new_stats}}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    current_sessions = :ets.info(state.table, :size)
    memory_usage = :ets.info(state.table, :memory) * :erlang.system_info(:wordsize)

    stats =
      Map.merge(state.stats, %{
        current_sessions: current_sessions,
        memory_usage_bytes: memory_usage,
        table_info: :ets.info(state.table)
      })

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:get_session, session_id}, _from, state) do
    case :ets.lookup(state.table, session_id) do
      [{^session_id, {_last_accessed, _ttl, session}}] ->
        # Touch the session to update last_accessed
        touched_session = Session.touch(session)
        # Store as {session_id, {last_accessed, ttl, session}} for efficient cleanup
        ets_record =
          {session_id, {touched_session.last_accessed, touched_session.ttl, touched_session}}

        :ets.insert(state.table, ets_record)
        {:reply, {:ok, touched_session}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:delete_session, session_id}, _from, state) do
    :ets.delete(state.table, session_id)
    new_stats = Map.update(state.stats, :sessions_deleted, 1, &(&1 + 1))
    {:reply, :ok, %{state | stats: new_stats}}
  end

  @impl true
  def handle_call(:list_sessions, _from, state) do
    session_ids = :ets.select(state.table, [{{:"$1", :_}, [], [:"$1"]}])
    {:reply, session_ids, state}
  end

  @impl true
  def handle_call({:session_exists, session_id}, _from, state) do
    exists =
      case :ets.lookup(state.table, session_id) do
        [{^session_id, _}] -> true
        [] -> false
      end

    {:reply, exists, state}
  end

  @impl true
  def handle_call({:store_global_program, program_id, program_data}, _from, state) do
    # Store with timestamp for potential TTL cleanup
    timestamp = System.monotonic_time(:second)
    program_entry = {program_id, program_data, timestamp}

    :ets.insert(state.global_programs_table, program_entry)

    new_stats = Map.update!(state.stats, :global_programs_stored, &(&1 + 1))
    {:reply, :ok, %{state | stats: new_stats}}
  end

  @impl true
  def handle_call({:get_global_program, program_id}, _from, state) do
    case :ets.lookup(state.global_programs_table, program_id) do
      [{^program_id, program_data, _timestamp}] ->
        {:reply, {:ok, program_data}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:delete_global_program, program_id}, _from, state) do
    :ets.delete(state.global_programs_table, program_id)

    new_stats = Map.update!(state.stats, :global_programs_deleted, &(&1 + 1))
    {:reply, :ok, %{state | stats: new_stats}}
  end

  @impl true
  def handle_call({:upsert_worker_session, session_id, worker_id}, _from, state) do
    case :ets.lookup(state.table, session_id) do
      [{^session_id, {_last_accessed, _ttl, session}}] ->
        # Session exists, update it
        updated_session =
          session
          |> Map.put(:last_worker_id, worker_id)
          |> Session.touch()

        # Store as {session_id, {last_accessed, ttl, session}} for efficient cleanup
        ets_record =
          {session_id, {updated_session.last_accessed, updated_session.ttl, updated_session}}

        :ets.insert(state.table, ets_record)
        {:reply, :ok, state}

      [] ->
        # Session doesn't exist, create it with worker affinity
        opts = [ttl: state.default_ttl]

        session =
          Session.new(session_id, opts)
          |> Map.put(:last_worker_id, worker_id)

        case Session.validate(session) do
          :ok ->
            # Store as {session_id, {last_accessed, ttl, session}} for efficient cleanup
            ets_record = {session_id, {session.last_accessed, session.ttl, session}}
            :ets.insert(state.table, ets_record)
            new_stats = Map.update(state.stats, :sessions_created, 1, &(&1 + 1))
            {:reply, :ok, %{state | stats: new_stats}}

          {:error, reason} ->
            # Session affinity is best-effort; log validation errors but don't fail
            Logger.warning("Failed to validate session for worker affinity: #{inspect(reason)}")
            {:reply, :ok, state}
        end
    end
  end

  @impl true
  def handle_call({:register_variable, session_id, name, type, initial_value, opts}, _from, state) do
    with {:ok, session} <- get_session_internal(state, session_id),
         {:ok, type_module} <- Types.get_type_module(type),
         {:ok, validated_value} <- type_module.validate(initial_value),
         constraints = get_option(opts, :constraints, %{}),
         :ok <- type_module.validate_constraints(validated_value, constraints) do
      var_id = generate_variable_id(name)
      now = System.monotonic_time(:second)

      variable =
        Variable.new(%{
          id: var_id,
          name: name,
          type: type,
          value: validated_value,
          constraints: constraints,
          metadata: build_variable_metadata(opts),
          version: 0,
          created_at: now,
          last_updated_at: now
        })

      updated_session = Session.put_variable(session, var_id, variable)
      new_state = store_session(state, session_id, updated_session)

      # Emit telemetry
      :telemetry.execute(
        [:snakepit, :session_store, :variable, :registered],
        %{count: 1},
        %{session_id: session_id, type: type}
      )

      Logger.info("Registered variable #{name} (#{var_id}) in session #{session_id}")

      {:reply, {:ok, var_id}, new_state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get_variable, session_id, identifier}, _from, state) do
    with {:ok, session} <- get_session_internal(state, session_id),
         {:ok, variable} <- Session.get_variable(session, identifier) do
      # Touch the session
      updated_session = Session.touch(session)
      new_state = store_session(state, session_id, updated_session)

      # Emit telemetry
      :telemetry.execute(
        [:snakepit, :session_store, :variable, :get],
        %{count: 1},
        %{session_id: session_id, cache_hit: false}
      )

      {:reply, {:ok, variable}, new_state}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:update_variable, session_id, identifier, new_value, metadata}, _from, state) do
    with {:ok, session} <- get_session_internal(state, session_id),
         {:ok, variable} <- Session.get_variable(session, identifier),
         {:ok, type_module} <- Types.get_type_module(variable.type),
         {:ok, validated_value} <- type_module.validate(new_value),
         :ok <- type_module.validate_constraints(validated_value, variable.constraints) do
      # Check if optimizing (Stage 4 feature)
      if Variable.optimizing?(variable) do
        {:reply, {:error, :variable_locked_for_optimization}, state}
      else
        updated_variable =
          Variable.update_value(variable, validated_value,
            metadata: metadata,
            source: Map.get(metadata, "source", "elixir")
          )

        updated_session = Session.put_variable(session, variable.id, updated_variable)
        new_state = store_session(state, session_id, updated_session)

        # Emit telemetry
        :telemetry.execute(
          [:snakepit, :session_store, :variable, :updated],
          %{count: 1, version: updated_variable.version},
          %{session_id: session_id, type: variable.type}
        )

        Logger.debug("Updated variable #{identifier} in session #{session_id}")

        # TODO: In Stage 3, notify observers here

        {:reply, :ok, new_state}
      end
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:list_variables, session_id}, _from, state) do
    with {:ok, session} <- get_session_internal(state, session_id) do
      variables = Session.list_variables(session)
      {:reply, {:ok, variables}, state}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:list_variables, session_id, pattern}, _from, state) do
    with {:ok, session} <- get_session_internal(state, session_id) do
      variables = Session.list_variables(session, pattern)
      {:reply, {:ok, variables}, state}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:delete_variable, session_id, identifier}, _from, state) do
    with {:ok, session} <- get_session_internal(state, session_id),
         {:ok, variable} <- Session.get_variable(session, identifier) do
      if Variable.optimizing?(variable) do
        {:reply, {:error, :variable_locked_for_optimization}, state}
      else
        updated_session = Session.delete_variable(session, identifier)
        new_state = store_session(state, session_id, updated_session)

        Logger.info("Deleted variable #{identifier} from session #{session_id}")

        {:reply, :ok, new_state}
      end
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:get_variables, session_id, identifiers}, _from, state) do
    with {:ok, session} <- get_session_internal(state, session_id) do
      result =
        Enum.reduce(identifiers, %{found: %{}, missing: []}, fn id, acc ->
          case Session.get_variable(session, id) do
            {:ok, variable} ->
              %{acc | found: Map.put(acc.found, to_string(id), variable)}

            {:error, :not_found} ->
              %{acc | missing: [to_string(id) | acc.missing]}
          end
        end)

      # Reverse missing list to maintain order
      result = %{result | missing: Enum.reverse(result.missing)}

      # Touch session
      updated_session = Session.touch(session)
      new_state = store_session(state, session_id, updated_session)

      {:reply, {:ok, result}, new_state}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:update_variables, session_id, updates, opts}, _from, state) do
    atomic = Keyword.get(opts, :atomic, false)
    metadata = get_option(opts, :metadata, %{})

    with {:ok, session} <- get_session_internal(state, session_id) do
      if atomic do
        handle_atomic_updates(session, updates, metadata, state, session_id)
      else
        handle_non_atomic_updates(session, updates, metadata, state, session_id)
      end
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:import_variables, session_id, variable_maps}, _from, state) do
    with {:ok, session} <- get_session_internal(state, session_id) do
      {updated_session, count} =
        Enum.reduce(variable_maps, {session, 0}, fn var_map, {sess, cnt} ->
          variable = Variable.new(var_map)
          {Session.put_variable(sess, variable.id, variable), cnt + 1}
        end)

      new_state = store_session(state, session_id, updated_session)

      Logger.info("Imported #{count} variables into session #{session_id}")

      {:reply, {:ok, count}, new_state}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info(:cleanup_expired_sessions, state) do
    {_expired_count, new_stats} = do_cleanup_expired_sessions(state.table, state.stats)

    {_expired_global_count, newer_stats} =
      do_cleanup_expired_global_programs(
        state.global_programs_table,
        state.global_program_ttl,
        new_stats
      )

    # Schedule next cleanup
    Process.send_after(self(), :cleanup_expired_sessions, state.cleanup_interval)

    {:noreply, %{state | stats: newer_stats}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("SessionStore received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @doc """
  Stores a program in a session.
  """
  @spec store_program(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def store_program(session_id, program_id, program_data) do
    update_session(session_id, fn session ->
      programs = Map.get(session, :programs, %{})
      updated_programs = Map.put(programs, program_id, program_data)
      Map.put(session, :programs, updated_programs)
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc """
  Updates a program in a session.
  """
  @spec update_program(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def update_program(session_id, program_id, program_data) do
    store_program(session_id, program_id, program_data)
  end

  @doc """
  Gets a program from a session.
  """
  @spec get_program(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_program(session_id, program_id) do
    case get_session(session_id) do
      {:ok, session} ->
        programs = Map.get(session, :programs, %{})

        case Map.get(programs, program_id) do
          nil -> {:error, :not_found}
          program_data -> {:ok, program_data}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Stores worker-session affinity mapping.
  """
  @spec store_worker_session(String.t(), String.t()) :: :ok
  def store_worker_session(session_id, worker_id) do
    GenServer.call(__MODULE__, {:upsert_worker_session, session_id, worker_id})
  end

  ## Private Functions

  defp do_cleanup_expired_sessions(table, stats) do
    current_time = System.monotonic_time(:second)

    # High-performance cleanup using ETS select_delete with optimized storage format
    # Match on {session_id, {last_accessed, ttl, _session}} where last_accessed + ttl < current_time
    match_spec = [
      {{:_, {:"$1", :"$2", :_}},
       [
         {:<, {:+, :"$1", :"$2"}, current_time}
       ], [true]}
    ]

    # Atomically find and delete all expired sessions using native ETS operations
    # This runs in C code and doesn't block the GenServer process
    expired_count = :ets.select_delete(table, match_spec)

    if expired_count > 0 do
      Logger.debug(
        "Cleaned up #{expired_count} expired sessions using high-performance select_delete"
      )
    end

    new_stats =
      stats
      |> Map.update(:sessions_expired, expired_count, &(&1 + expired_count))
      |> Map.update(:cleanup_runs, 1, &(&1 + 1))

    {expired_count, new_stats}
  end

  # Clean up expired global programs using efficient ETS select_delete
  defp do_cleanup_expired_global_programs(table, ttl, stats) do
    current_time = System.monotonic_time(:second)
    expiration_time = current_time - ttl

    # Match spec: {program_id, _program_data, timestamp} where timestamp < expiration_time
    # In the tuple: program_id is at element 1, program_data is at element 2, timestamp is at element 3
    match_spec = [
      {{:_, :_, :"$1"}, [{:<, :"$1", expiration_time}], [true]}
    ]

    # Atomically find and delete all expired global programs
    expired_count = :ets.select_delete(table, match_spec)

    if expired_count > 0 do
      Logger.debug("Cleaned up #{expired_count} expired global programs")
    end

    new_stats = Map.update(stats, :global_programs_expired, expired_count, &(&1 + expired_count))

    {expired_count, new_stats}
  end

  # Private helpers for variable operations

  defp get_option(opts, key, default) when is_map(opts) do
    Map.get(opts, key, default)
  end

  defp get_option(opts, key, default) when is_list(opts) do
    Keyword.get(opts, key, default)
  end

  defp get_option(_, _, default), do: default

  defp get_session_internal(state, session_id) do
    case :ets.lookup(state.table, session_id) do
      [{^session_id, {_last_accessed, _ttl, session}}] -> {:ok, session}
      [] -> {:error, :session_not_found}
    end
  end

  defp store_session(state, session_id, session) do
    touched_session = Session.touch(session)

    ets_record =
      {session_id, {touched_session.last_accessed, touched_session.ttl, touched_session}}

    :ets.insert(state.table, ets_record)
    state
  end

  defp generate_variable_id(name) do
    timestamp = System.unique_integer([:positive, :monotonic])
    "var_#{name}_#{timestamp}"
  end

  defp build_variable_metadata(opts) do
    base_metadata = %{
      "source" => "elixir",
      "created_by" => "session_store"
    }

    # Add description if provided
    base_metadata =
      if desc = get_option(opts, :description, nil) do
        Map.put(base_metadata, "description", desc)
      else
        base_metadata
      end

    # Merge any additional metadata
    Map.merge(base_metadata, get_option(opts, :metadata, %{}))
  end

  defp handle_atomic_updates(session, updates, metadata, state, session_id) do
    # First validate all updates
    validation_results =
      Enum.reduce(updates, %{}, fn {id, value}, acc ->
        case validate_update(session, id, value) do
          :ok -> acc
          {:error, reason} -> Map.put(acc, to_string(id), reason)
        end
      end)

    if map_size(validation_results) == 0 do
      # All valid, apply updates
      {updated_session, results} =
        Enum.reduce(updates, {session, %{}}, fn {id, value}, {sess, res} ->
          case apply_update(sess, id, value, metadata) do
            {:ok, new_sess} ->
              {new_sess, Map.put(res, to_string(id), :ok)}

            {:error, reason} ->
              # Shouldn't happen after validation
              {sess, Map.put(res, to_string(id), {:error, reason})}
          end
        end)

      new_state = store_session(state, session_id, updated_session)
      {:reply, {:ok, results}, new_state}
    else
      # Validation failed, return errors
      {:reply, {:error, {:validation_failed, validation_results}}, state}
    end
  end

  defp handle_non_atomic_updates(session, updates, metadata, state, session_id) do
    {updated_session, results} =
      Enum.reduce(updates, {session, %{}}, fn {id, value}, {sess, res} ->
        case apply_update(sess, id, value, metadata) do
          {:ok, new_sess} ->
            {new_sess, Map.put(res, to_string(id), :ok)}

          {:error, reason} ->
            {sess, Map.put(res, to_string(id), {:error, reason})}
        end
      end)

    new_state = store_session(state, session_id, updated_session)
    {:reply, {:ok, results}, new_state}
  end

  defp validate_update(session, identifier, value) do
    with {:ok, variable} <- Session.get_variable(session, identifier),
         {:ok, type_module} <- Types.get_type_module(variable.type),
         {:ok, validated_value} <- type_module.validate(value),
         :ok <- type_module.validate_constraints(validated_value, variable.constraints) do
      :ok
    end
  end

  defp apply_update(session, identifier, value, metadata) do
    with {:ok, variable} <- Session.get_variable(session, identifier),
         {:ok, type_module} <- Types.get_type_module(variable.type),
         {:ok, validated_value} <- type_module.validate(value),
         :ok <- type_module.validate_constraints(validated_value, variable.constraints) do
      updated_variable = Variable.update_value(variable, validated_value, metadata: metadata)
      updated_session = Session.put_variable(session, variable.id, updated_variable)

      {:ok, updated_session}
    end
  end
end
