defmodule Snakepit.Bridge.Session do
  @moduledoc """
  Session data structure for centralized session management.

  Stores program metadata and session state for worker affinity.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          programs: map(),
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
    metadata: %{},
    stats: %{
      program_count: 0
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
    with :ok <- validate_basic_fields(session),
         :ok <- validate_time_fields(session) do
      validate_worker_field(session.last_worker_id)
    end
  end

  def validate(_), do: {:error, :not_a_session}

  defp validate_basic_fields(session) do
    with :ok <- validate_id(session.id),
         :ok <- validate_programs(session.programs) do
      validate_metadata_field(session.metadata)
    end
  end

  defp validate_time_fields(session) do
    with :ok <- validate_created_at(session.created_at),
         :ok <- validate_last_accessed(session.last_accessed),
         :ok <- validate_ttl(session.ttl) do
      validate_timestamps(session.created_at, session.last_accessed)
    end
  end

  defp validate_worker_field(nil), do: :ok
  defp validate_worker_field(id) when is_binary(id), do: :ok
  defp validate_worker_field(_), do: {:error, :invalid_last_worker_id}

  defp validate_id(id) when is_binary(id) and id != "", do: :ok
  defp validate_id(_), do: {:error, :invalid_id}

  defp validate_programs(programs) when is_map(programs), do: :ok
  defp validate_programs(_), do: {:error, :invalid_programs}

  defp validate_metadata_field(metadata) when is_map(metadata), do: :ok
  defp validate_metadata_field(_), do: {:error, :invalid_metadata}

  defp validate_created_at(created_at) when is_integer(created_at), do: :ok
  defp validate_created_at(_), do: {:error, :invalid_created_at}

  defp validate_last_accessed(last_accessed) when is_integer(last_accessed), do: :ok
  defp validate_last_accessed(_), do: {:error, :invalid_last_accessed}

  defp validate_ttl(ttl) when is_integer(ttl) and ttl >= 0, do: :ok
  defp validate_ttl(_), do: {:error, :invalid_ttl}

  defp validate_timestamps(created_at, last_accessed) when last_accessed >= created_at, do: :ok
  defp validate_timestamps(_, _), do: {:error, :invalid_timestamps}

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
      if is_update do
        session.stats
      else
        %{session.stats | program_count: session.stats.program_count + 1}
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
  Gets session statistics.
  """
  @spec get_stats(t()) :: map()
  def get_stats(%__MODULE__{} = session) do
    Map.merge(session.stats, %{
      age: System.monotonic_time(:second) - session.created_at,
      time_since_access: System.monotonic_time(:second) - session.last_accessed,
      total_items: session.stats.program_count
    })
  end
end
