defmodule Snakepit.Bridge.Session do
  @moduledoc """
  Session data structure for centralized session management.

  Extended in Stage 1 to support variables alongside programs.
  Variables are stored by ID with a name index for fast lookups.
  """

  alias Snakepit.Bridge.Variables.Variable

  @type t :: %__MODULE__{
          id: String.t(),
          programs: map(),
          variables: %{String.t() => Variable.t()},
          # name -> id mapping
          variable_index: %{String.t() => String.t()},
          metadata: map(),
          created_at: integer(),
          last_accessed: integer(),
          last_worker_id: String.t() | nil,
          ttl: integer(),
          stats: map()
        }

  @enforce_keys [:id, :created_at, :ttl]
  defstruct [
    :id,
    :created_at,
    :last_accessed,
    :last_worker_id,
    :ttl,
    programs: %{},
    variables: %{},
    variable_index: %{},
    metadata: %{},
    stats: %{
      variable_count: 0,
      program_count: 0,
      total_variable_updates: 0
    }
  ]

  @doc """
  Creates a new session with the given ID and options.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(id, opts \\ []) when is_binary(id) do
    now = System.monotonic_time(:second)
    # 1 hour default
    ttl = Keyword.get(opts, :ttl, 3600)
    metadata = Keyword.get(opts, :metadata, %{})

    %__MODULE__{
      id: id,
      created_at: now,
      last_accessed: now,
      ttl: ttl,
      metadata: metadata,
      programs: Keyword.get(opts, :programs, %{}),
      last_worker_id: Keyword.get(opts, :last_worker_id, nil)
    }
  end

  @doc """
  Updates the last_accessed timestamp to the current time.

  ## Parameters

  - `session` - The session to touch

  ## Returns

  Updated session with current last_accessed timestamp.
  """
  @spec touch(t()) :: t()
  def touch(%__MODULE__{} = session) do
    %{session | last_accessed: System.monotonic_time(:second)}
  end

  @doc """
  Checks if a session has expired based on its TTL.

  ## Parameters

  - `session` - The session to check
  - `current_time` - Optional current time (defaults to current monotonic time)

  ## Returns

  `true` if the session has expired, `false` otherwise.
  """
  @spec expired?(t(), integer() | nil) :: boolean()
  def expired?(%__MODULE__{} = session, current_time \\ nil) do
    current_time = current_time || System.monotonic_time(:second)
    session.last_accessed + session.ttl < current_time
  end

  @doc """
  Validates that a session struct has all required fields and valid data.

  ## Parameters

  - `session` - The session to validate

  ## Returns

  `:ok` if valid, `{:error, reason}` if invalid.
  """
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = session) do
    cond do
      not is_binary(session.id) or session.id == "" ->
        {:error, :invalid_id}

      not is_map(session.programs) ->
        {:error, :invalid_programs}

      not is_map(session.metadata) ->
        {:error, :invalid_metadata}

      not is_integer(session.created_at) ->
        {:error, :invalid_created_at}

      not is_integer(session.last_accessed) ->
        {:error, :invalid_last_accessed}

      not (is_binary(session.last_worker_id) or is_nil(session.last_worker_id)) ->
        {:error, :invalid_last_worker_id}

      not is_integer(session.ttl) or session.ttl < 0 ->
        {:error, :invalid_ttl}

      session.last_accessed < session.created_at ->
        {:error, :invalid_timestamps}

      true ->
        :ok
    end
  end

  def validate(_), do: {:error, :not_a_session}

  @doc """
  Adds or updates a program in the session.

  ## Parameters

  - `session` - The session to update
  - `program_id` - The program identifier
  - `program_data` - The program data to store

  ## Returns

  Updated session with the program added/updated.
  """
  @spec put_program(t(), String.t(), term()) :: t()
  def put_program(%__MODULE__{} = session, program_id, program_data)
      when is_binary(program_id) do
    is_update = Map.has_key?(session.programs, program_id)
    programs = Map.put(session.programs, program_id, program_data)

    stats =
      if not is_update do
        %{session.stats | program_count: session.stats.program_count + 1}
      else
        session.stats
      end

    %{session | programs: programs, stats: stats}
  end

  @doc """
  Gets a program from the session.

  ## Parameters

  - `session` - The session to query
  - `program_id` - The program identifier

  ## Returns

  `{:ok, program_data}` if found, `{:error, :not_found}` if not found.
  """
  @spec get_program(t(), String.t()) :: {:ok, term()} | {:error, :not_found}
  def get_program(%__MODULE__{} = session, program_id) when is_binary(program_id) do
    case Map.get(session.programs, program_id) do
      nil -> {:error, :not_found}
      program_data -> {:ok, program_data}
    end
  end

  @doc """
  Removes a program from the session.

  ## Parameters

  - `session` - The session to update
  - `program_id` - The program identifier to remove

  ## Returns

  Updated session with the program removed.
  """
  @spec delete_program(t(), String.t()) :: t()
  def delete_program(%__MODULE__{} = session, program_id) when is_binary(program_id) do
    programs = Map.delete(session.programs, program_id)
    %{session | programs: programs}
  end

  @doc """
  Updates session metadata.

  ## Parameters

  - `session` - The session to update
  - `key` - The metadata key
  - `value` - The metadata value

  ## Returns

  Updated session with the metadata updated.
  """
  @spec put_metadata(t(), term(), term()) :: t()
  def put_metadata(%__MODULE__{} = session, key, value) do
    metadata = Map.put(session.metadata, key, value)
    %{session | metadata: metadata}
  end

  @doc """
  Gets metadata from the session.

  ## Parameters

  - `session` - The session to query
  - `key` - The metadata key
  - `default` - Default value if key not found

  ## Returns

  The metadata value or the default.
  """
  @spec get_metadata(t(), term(), term()) :: term()
  def get_metadata(%__MODULE__{} = session, key, default \\ nil) do
    Map.get(session.metadata, key, default)
  end

  @doc """
  Adds or updates a variable in the session.

  Updates both the variables map and the name index.
  Also updates session statistics.
  """
  @spec put_variable(t(), String.t(), Variable.t()) :: t()
  def put_variable(%__MODULE__{} = session, var_id, %Variable{} = variable)
      when is_binary(var_id) do
    # Check if it's an update
    is_update = Map.has_key?(session.variables, var_id)

    # Update variables map
    variables = Map.put(session.variables, var_id, variable)

    # Update name index
    variable_index = Map.put(session.variable_index, to_string(variable.name), var_id)

    # Update stats
    stats =
      if is_update do
        %{session.stats | total_variable_updates: session.stats.total_variable_updates + 1}
      else
        %{
          session.stats
          | variable_count: session.stats.variable_count + 1,
            total_variable_updates: session.stats.total_variable_updates + 1
        }
      end

    %{session | variables: variables, variable_index: variable_index, stats: stats}
  end

  @doc """
  Gets a variable by ID or name.

  Supports both atom and string identifiers. Names are resolved
  through the variable index for O(1) lookup.
  """
  @spec get_variable(t(), String.t() | atom()) :: {:ok, Variable.t()} | {:error, :not_found}
  def get_variable(%__MODULE__{} = session, identifier) when is_atom(identifier) do
    get_variable(session, to_string(identifier))
  end

  def get_variable(%__MODULE__{} = session, identifier) when is_binary(identifier) do
    # First check if it's a direct ID
    case Map.get(session.variables, identifier) do
      nil ->
        # Try to resolve as a name through the index
        case Map.get(session.variable_index, identifier) do
          nil ->
            {:error, :not_found}

          var_id ->
            # Get by resolved ID
            case Map.get(session.variables, var_id) do
              # Shouldn't happen
              nil -> {:error, :not_found}
              variable -> {:ok, variable}
            end
        end

      variable ->
        {:ok, variable}
    end
  end

  @doc """
  Removes a variable from the session.
  """
  @spec delete_variable(t(), String.t() | atom()) :: t()
  def delete_variable(%__MODULE__{} = session, identifier) do
    case get_variable(session, identifier) do
      {:ok, variable} ->
        # Remove from variables
        variables = Map.delete(session.variables, variable.id)

        # Remove from index
        variable_index = Map.delete(session.variable_index, to_string(variable.name))

        # Update stats
        stats = %{session.stats | variable_count: session.stats.variable_count - 1}

        %{session | variables: variables, variable_index: variable_index, stats: stats}

      {:error, :not_found} ->
        session
    end
  end

  @doc """
  Lists all variables in the session.

  Returns them sorted by creation time (oldest first).
  """
  @spec list_variables(t()) :: [Variable.t()]
  def list_variables(%__MODULE__{} = session) do
    session.variables
    |> Map.values()
    |> Enum.sort_by(& &1.created_at)
  end

  @doc """
  Lists variables matching a pattern.

  Supports wildcards: "temp_*" matches "temp_1", "temp_2", etc.
  """
  @spec list_variables(t(), String.t()) :: [Variable.t()]
  def list_variables(%__MODULE__{} = session, pattern) when is_binary(pattern) do
    regex =
      pattern
      |> String.replace("*", ".*")
      |> Regex.compile!()

    session.variables
    |> Map.values()
    |> Enum.filter(fn var ->
      Regex.match?(regex, to_string(var.name))
    end)
    |> Enum.sort_by(& &1.created_at)
  end

  @doc """
  Checks if a variable exists by name or ID.
  """
  @spec has_variable?(t(), String.t() | atom()) :: boolean()
  def has_variable?(%__MODULE__{} = session, identifier) do
    case get_variable(session, identifier) do
      {:ok, _} -> true
      {:error, :not_found} -> false
    end
  end

  @doc """
  Gets all variable names in the session.
  """
  @spec variable_names(t()) :: [String.t()]
  def variable_names(%__MODULE__{} = session) do
    Map.keys(session.variable_index)
  end

  @doc """
  Gets session statistics.
  """
  @spec get_stats(t()) :: map()
  def get_stats(%__MODULE__{} = session) do
    Map.merge(session.stats, %{
      age: System.monotonic_time(:second) - session.created_at,
      time_since_access: System.monotonic_time(:second) - session.last_accessed,
      total_items: session.stats.variable_count + session.stats.program_count
    })
  end
end
