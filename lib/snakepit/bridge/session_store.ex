defmodule Snakepit.Bridge.SessionStore do
  @moduledoc """
  Centralized session store using ETS for high-performance session management.

  This GenServer manages a centralized ETS table for storing session data,
  providing CRUD operations, TTL-based expiration, and automatic cleanup.
  The store is designed for high concurrency with optimized ETS settings.
  """

  use GenServer
  alias Snakepit.Bridge.Session
  alias Snakepit.Defaults
  alias Snakepit.Logger, as: SLog

  @log_category :bridge
  @default_table_name :snakepit_sessions

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
        Map.put(session, :data, %{key: "value"})
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

  @doc """
  Stores worker-session affinity mapping.
  """
  @spec store_worker_session(String.t(), String.t()) :: :ok | {:error, :session_quota_exceeded}
  def store_worker_session(session_id, worker_id) do
    GenServer.call(__MODULE__, {:upsert_worker_session, session_id, worker_id})
  end

  @spec store_worker_session(GenServer.server(), String.t(), String.t()) ::
          :ok | {:error, :session_quota_exceeded}
  def store_worker_session(server, session_id, worker_id)
      when is_binary(session_id) and is_binary(worker_id) do
    GenServer.call(server, {:upsert_worker_session, session_id, worker_id})
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table_name, @default_table_name)

    table =
      :ets.new(table_name, [
        :set,
        :protected,
        :named_table,
        {:read_concurrency, true},
        {:write_concurrency, true},
        {:decentralized_counters, true}
      ])

    cleanup_interval = Keyword.get(opts, :cleanup_interval, Defaults.session_cleanup_interval())
    default_ttl = Keyword.get(opts, :default_ttl, Defaults.session_default_ttl())

    quota_config = Application.get_env(:snakepit, :session_store, %{})

    max_sessions =
      resolve_quota(opts, quota_config, :max_sessions, Defaults.session_max_sessions())

    # Strict mode for dev/test - warns loudly on session accumulation
    strict_mode = Keyword.get(opts, :strict_mode, Map.get(quota_config, :strict_mode, false))

    Process.send_after(self(), :cleanup_expired_sessions, cleanup_interval)

    state = %{
      table: table,
      table_name: table_name,
      cleanup_interval: cleanup_interval,
      default_ttl: default_ttl,
      max_sessions: max_sessions,
      strict_mode: strict_mode,
      stats: %{
        sessions_created: 0,
        sessions_deleted: 0,
        sessions_expired: 0,
        cleanup_runs: 0
      }
    }

    SLog.info(@log_category, "SessionStore started with table #{table}")

    {:ok, state}
  end

  @impl true
  def handle_call({:create_session, session_id, opts}, _from, state) do
    opts = Keyword.put_new(opts, :ttl, state.default_ttl)
    session = Session.new(session_id, opts)

    with :ok <- Session.validate(session),
         :ok <- check_session_quota(state) do
      insert_new_session(session_id, session, state)
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
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
              touched_session = Session.touch(updated_session)

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
            SLog.error(@log_category, "Error updating session #{session_id}: #{inspect(error)}")
            {:reply, {:error, {:update_failed, error}}, state}
        catch
          kind, reason ->
            SLog.error(
              @log_category,
              "Non-exception failure updating session #{session_id}",
              kind: kind,
              reason: reason
            )

            {:reply, {:error, {:update_failed, {kind, reason}}}, state}
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
        touched_session = Session.touch(session)

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
  def handle_call({:upsert_worker_session, session_id, worker_id}, _from, state) do
    case :ets.lookup(state.table, session_id) do
      [{^session_id, {_last_accessed, _ttl, session}}] ->
        updated_session =
          session
          |> Map.put(:last_worker_id, worker_id)
          |> Session.touch()

        ets_record =
          {session_id, {updated_session.last_accessed, updated_session.ttl, updated_session}}

        :ets.insert(state.table, ets_record)
        {:reply, :ok, state}

      [] ->
        opts = [ttl: state.default_ttl]

        session =
          Session.new(session_id, opts)
          |> Map.put(:last_worker_id, worker_id)

        with :ok <- Session.validate(session),
             :ok <- check_session_quota(state) do
          ets_record = {session_id, {session.last_accessed, session.ttl, session}}
          :ets.insert(state.table, ets_record)
          new_stats = Map.update(state.stats, :sessions_created, 1, &(&1 + 1))
          {:reply, :ok, %{state | stats: new_stats}}
        else
          {:error, :session_quota_exceeded} ->
            {:reply, {:error, :session_quota_exceeded}, state}

          {:error, reason} ->
            SLog.warning(
              @log_category,
              "Failed to validate session for worker affinity: #{inspect(reason)}"
            )

            {:reply, :ok, state}
        end
    end
  end

  @impl true
  def handle_info(:cleanup_expired_sessions, state) do
    {expired_count, new_stats} = do_cleanup_expired_sessions(state.table, state.stats)

    # Emit telemetry for session pruning
    if expired_count > 0 do
      emit_cleanup_telemetry(state, expired_count, :ttl)
    end

    # Check session accumulation thresholds and warn if needed
    maybe_warn_session_accumulation(state)

    Process.send_after(self(), :cleanup_expired_sessions, state.cleanup_interval)
    {:noreply, %{state | stats: new_stats}}
  end

  @impl true
  def handle_info(msg, state) do
    SLog.warning(@log_category, "SessionStore received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  ## Private Functions

  defp do_cleanup_expired_sessions(table, stats) do
    current_time = System.monotonic_time(:second)

    match_spec = [
      {{:_, {:"$1", :"$2", :_}},
       [
         {:<, {:+, :"$1", :"$2"}, current_time}
       ], [true]}
    ]

    expired_count = :ets.select_delete(table, match_spec)

    if expired_count > 0 do
      SLog.debug(
        @log_category,
        "Cleaned up #{expired_count} expired sessions using high-performance select_delete"
      )
    end

    new_stats =
      stats
      |> Map.update(:sessions_expired, expired_count, &(&1 + expired_count))
      |> Map.update(:cleanup_runs, 1, &(&1 + 1))

    {expired_count, new_stats}
  end

  defp resolve_quota(opts, config, key, default) do
    value = Keyword.get(opts, key, Map.get(config, key, default))
    normalize_quota(value, default)
  end

  defp normalize_quota(:infinity, _default), do: :infinity

  defp normalize_quota(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_quota(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} when int > 0 -> int
      _ -> default
    end
  end

  defp normalize_quota(_value, default), do: default

  defp session_quota_reached?(%{max_sessions: :infinity}), do: false

  defp session_quota_reached?(state) do
    :ets.info(state.table, :size) >= state.max_sessions
  end

  defp check_session_quota(state) do
    if session_quota_reached?(state) do
      {:error, :session_quota_exceeded}
    else
      :ok
    end
  end

  defp insert_new_session(session_id, session, state) do
    ets_record = {session_id, {session.last_accessed, session.ttl, session}}

    case :ets.insert_new(state.table, ets_record) do
      true ->
        SLog.debug(@log_category, "Created new session: #{session_id}")
        new_stats = Map.update(state.stats, :sessions_created, 1, &(&1 + 1))
        {:reply, {:ok, session}, %{state | stats: new_stats}}

      false ->
        SLog.debug(
          @log_category,
          "Session #{session_id} already exists - reusing (concurrent init)"
        )

        [{^session_id, {_last_accessed, _ttl, existing_session}}] =
          :ets.lookup(state.table, session_id)

        {:reply, {:ok, existing_session}, state}
    end
  end

  # Telemetry emission for session pruning events
  defp emit_cleanup_telemetry(state, count, reason) do
    current_sessions = :ets.info(state.table, :size)

    :telemetry.execute(
      [:snakepit, :bridge, :session, :pruned],
      %{
        count: count,
        remaining_sessions: current_sessions,
        system_time: System.system_time()
      },
      %{
        reason: reason,
        table_name: state.table_name,
        max_sessions: state.max_sessions
      }
    )
  end

  # Warn on session accumulation in strict mode or when approaching limits
  defp maybe_warn_session_accumulation(state) do
    current_sessions = :ets.info(state.table, :size)
    max_sessions = state.max_sessions

    cond do
      max_sessions == :infinity ->
        :ok

      current_sessions >= max_sessions ->
        emit_accumulation_warning(state, current_sessions, :quota_exceeded)

        if state.strict_mode do
          SLog.warning(
            @log_category,
            """
            [STRICT MODE] Session quota exceeded!
            Current: #{current_sessions}, Max: #{max_sessions}
            Sessions are being rejected. Check for session leaks.
            """
          )
        end

      current_sessions >= trunc(max_sessions * Defaults.session_warning_threshold()) ->
        emit_accumulation_warning(state, current_sessions, :threshold_warning)

        if state.strict_mode do
          utilization = Float.round(current_sessions / max_sessions * 100, 1)

          SLog.warning(
            @log_category,
            """
            [STRICT MODE] High session count warning!
            Current: #{current_sessions}, Max: #{max_sessions} (#{utilization}% utilization)
            Consider checking for session leaks or increasing max_sessions.
            """
          )
        end

      true ->
        :ok
    end
  end

  defp emit_accumulation_warning(state, current_sessions, reason) do
    :telemetry.execute(
      [:snakepit, :bridge, :session, :accumulation_warning],
      %{
        current_sessions: current_sessions,
        max_sessions: state.max_sessions,
        utilization:
          if(state.max_sessions != :infinity,
            do: current_sessions / state.max_sessions,
            else: 0.0
          ),
        system_time: System.system_time()
      },
      %{
        reason: reason,
        table_name: state.table_name,
        strict_mode: state.strict_mode
      }
    )
  end
end
