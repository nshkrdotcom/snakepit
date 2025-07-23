defmodule Snakepit.Bridge.Variables.Types do
  @moduledoc """
  Type system for bridge variables with serialization support.

  Provides a behaviour for implementing variable types and
  a registry for looking up type implementations.
  """

  @type var_type ::
          :float | :integer | :string | :boolean | :choice | :module | :embedding | :tensor

  @doc """
  Get the type module for a given type atom.
  """
  def get_type_module(:float), do: {:ok, __MODULE__.Float}
  def get_type_module(:integer), do: {:ok, __MODULE__.Integer}
  def get_type_module(:string), do: {:ok, __MODULE__.String}
  def get_type_module(:boolean), do: {:ok, __MODULE__.Boolean}
  def get_type_module(:choice), do: {:ok, __MODULE__.Choice}
  def get_type_module(:module), do: {:ok, __MODULE__.Module}
  def get_type_module(:embedding), do: {:ok, __MODULE__.Embedding}
  def get_type_module(:tensor), do: {:ok, __MODULE__.Tensor}

  def get_type_module(type) when is_binary(type) do
    try do
      get_type_module(String.to_existing_atom(type))
    rescue
      ArgumentError -> {:error, {:unknown_type, type}}
    end
  end

  def get_type_module(type), do: {:error, {:unknown_type, type}}

  @doc """
  Lists all supported variable types.
  """
  def list_types do
    [:float, :integer, :string, :boolean, :choice, :module, :embedding, :tensor]
  end

  @doc """
  Validates a value against a type.
  """
  @spec validate_value(any(), atom(), map()) :: {:ok, any()} | {:error, String.t()}
  def validate_value(value, type, constraints \\ %{}) do
    with {:ok, module} <- get_type_module(type),
         {:ok, validated} <- module.validate(value),
         :ok <- module.validate_constraints(validated, constraints) do
      {:ok, validated}
    end
  end

  @doc """
  Checks if a value would be valid for a type without modifying it.
  """
  @spec valid?(any(), atom(), map()) :: boolean()
  def valid?(value, type, constraints \\ %{}) do
    case validate_value(value, type, constraints) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Infers the type of a value based on its Elixir type.
  """
  @spec infer_type(any()) :: var_type()
  def infer_type(value) when is_boolean(value), do: :boolean
  def infer_type(value) when is_integer(value), do: :integer
  def infer_type(value) when is_float(value), do: :float
  def infer_type(value) when is_binary(value), do: :string
  def infer_type(value) when is_list(value) do
    # Check if it's a numeric list that could be an embedding
    if Enum.all?(value, &is_number/1), do: :embedding, else: :string
  end
  def infer_type(value) when is_map(value) do
    # Check if it looks like a tensor
    if Map.has_key?(value, "shape") and Map.has_key?(value, "data"), do: :tensor, else: :string
  end
  def infer_type(_value), do: :string

  defmodule Behaviour do
    @moduledoc """
    Common behaviour for all types.
    """
    @callback validate(value :: any()) ::
                {:ok, normalized :: any()} | {:error, reason :: String.t()}
    @callback validate_constraints(value :: any(), constraints :: map()) ::
                :ok | {:error, reason :: String.t()}
    @callback serialize(value :: any()) ::
                {:ok, json :: String.t()} | {:error, reason :: String.t()}
    @callback deserialize(json :: String.t()) ::
                {:ok, value :: any()} | {:error, reason :: String.t()}
  end
end
