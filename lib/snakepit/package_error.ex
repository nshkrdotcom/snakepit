defmodule Snakepit.PackageError do
  @moduledoc """
  Structured error for Python package installation and inspection.
  """

  defexception [:type, :packages, :message, :suggestion, :output]

  @type type ::
          :not_installed
          | :install_failed
          | :version_mismatch
          | :invalid_requirement

  @type t :: %__MODULE__{
          type: type(),
          packages: [String.t()],
          message: String.t(),
          suggestion: String.t() | nil,
          output: String.t() | nil
        }

  @impl true
  def message(%__MODULE__{message: message, suggestion: suggestion}) do
    base = message || "Python package error"

    if suggestion do
      base <> "\nSuggestion: " <> suggestion
    else
      base
    end
  end
end
