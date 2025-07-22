defmodule Snakepit.Bridge.Variables.Types do
  @moduledoc """
  Type system for bridge variables with serialization support.
  """
  
  @type var_type :: :float | :integer | :string | :boolean | 
                    :choice | :module | :embedding | :tensor
  
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
  def get_type_module(_), do: {:error, :unknown_type}
  
  @doc """
  Common behaviour for all types.
  """
  defmodule Behaviour do
    @callback validate(value :: any()) :: {:ok, normalized :: any()} | {:error, reason :: String.t()}
    @callback validate_constraints(value :: any(), constraints :: map()) :: :ok | {:error, reason :: String.t()}
    @callback serialize(value :: any()) :: {:ok, json :: String.t()} | {:error, reason :: String.t()}
    @callback deserialize(json :: String.t()) :: {:ok, value :: any()} | {:error, reason :: String.t()}
  end
end