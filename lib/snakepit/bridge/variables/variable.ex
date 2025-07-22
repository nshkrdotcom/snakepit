defmodule Snakepit.Bridge.Variables.Variable do
  @moduledoc """
  Variable struct and related functions.

  Variables are typed, versioned values that can be synchronized
  between Elixir and Python processes. They form the core of the
  DSPex state management system.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | atom(),
          type: atom(),
          value: any(),
          constraints: map(),
          metadata: map(),
          version: integer(),
          created_at: integer(),
          last_updated_at: integer(),
          optimization_status: map(),
          access_rules: list()
        }

  @enforce_keys [:id, :name, :type, :value, :created_at]
  defstruct [
    :id,
    :name,
    :type,
    :value,
    constraints: %{},
    metadata: %{},
    version: 0,
    created_at: nil,
    last_updated_at: nil,
    optimization_status: %{
      optimizing: false,
      optimizer_id: nil,
      optimizer_pid: nil,
      started_at: nil
    },
    # For future Stage 4
    access_rules: []
  ]

  @doc """
  Creates a new variable with validation.

  ## Examples
      
      iex> Variable.new(%{
      ...>   id: "var_temp_123",
      ...>   name: :temperature,
      ...>   type: :float,
      ...>   value: 0.7,
      ...>   created_at: System.monotonic_time(:second)
      ...> })
      %Variable{...}
  """
  def new(attrs) when is_map(attrs) do
    # Ensure required fields
    required = [:id, :name, :type, :value, :created_at]
    missing = required -- Map.keys(attrs)

    if missing != [] do
      raise ArgumentError, "Missing required fields: #{inspect(missing)}"
    end

    # Set last_updated_at if not provided
    attrs = Map.put_new(attrs, :last_updated_at, attrs.created_at)

    struct!(__MODULE__, attrs)
  end

  @doc """
  Updates a variable's value and increments version.

  ## Options
    * `:metadata` - Additional metadata to merge
    * `:source` - Source of the update (defaults to :elixir)
  """
  @spec update_value(t(), any(), keyword()) :: t()
  def update_value(%__MODULE__{} = variable, new_value, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})
    source = Keyword.get(opts, :source, :elixir)

    now = System.monotonic_time(:second)

    %{
      variable
      | value: new_value,
        version: variable.version + 1,
        last_updated_at: now,
        metadata:
          Map.merge(
            variable.metadata,
            Map.merge(metadata, %{
              "source" => to_string(source),
              "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
            })
          )
    }
  end

  @doc """
  Checks if a variable is currently being optimized.
  """
  @spec optimizing?(t()) :: boolean()
  def optimizing?(%__MODULE__{optimization_status: status}) do
    status.optimizing == true
  end

  @doc """
  Marks a variable as being optimized.
  """
  @spec start_optimization(t(), String.t(), pid()) :: t()
  def start_optimization(%__MODULE__{} = variable, optimizer_id, optimizer_pid) do
    %{
      variable
      | optimization_status: %{
          optimizing: true,
          optimizer_id: optimizer_id,
          optimizer_pid: optimizer_pid,
          started_at: System.monotonic_time(:second)
        }
    }
  end

  @doc """
  Clears optimization status.
  """
  @spec end_optimization(t()) :: t()
  def end_optimization(%__MODULE__{} = variable) do
    %{
      variable
      | optimization_status: %{
          optimizing: false,
          optimizer_id: nil,
          optimizer_pid: nil,
          started_at: nil
        }
    }
  end

  @doc """
  Converts variable to a map suitable for JSON encoding.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = variable) do
    result = %{
      id: variable.id,
      name: to_string(variable.name),
      type: variable.type,
      value: variable.value,
      constraints: variable.constraints,
      metadata: variable.metadata,
      version: variable.version,
      created_at: variable.created_at,
      last_updated_at: variable.last_updated_at,
      optimization_status: variable.optimization_status,
      access_rules: variable.access_rules
    }

    # Debug output
    require Logger

    Logger.debug(
      "Variable.to_map for #{variable.name}: exporting fields #{inspect(Map.keys(result))}"
    )

    result
  end

  @doc """
  Converts variable to a map for export, excluding internal fields.
  This is useful for serialization to external systems.
  """
  @spec to_export_map(t()) :: map()
  def to_export_map(%__MODULE__{} = variable) do
    # Only include essential fields for export
    result = %{
      id: variable.id,
      name: to_string(variable.name),
      type: variable.type,
      value: variable.value,
      constraints: variable.constraints,
      metadata: variable.metadata,
      version: variable.version,
      created_at: variable.created_at,
      last_updated_at: variable.last_updated_at
    }

    # Debug output
    require Logger

    Logger.debug(
      "Variable.to_export_map for #{variable.name}: exporting minimal fields #{inspect(Map.keys(result))}"
    )

    result
  end

  @doc """
  Gets the age of the variable in seconds.
  """
  @spec age(t()) :: integer()
  def age(%__MODULE__{created_at: created_at}) do
    System.monotonic_time(:second) - created_at
  end

  @doc """
  Gets time since last update in seconds.
  """
  @spec time_since_update(t()) :: integer()
  def time_since_update(%__MODULE__{last_updated_at: last_updated}) do
    System.monotonic_time(:second) - last_updated
  end
end
