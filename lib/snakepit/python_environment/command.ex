defmodule Snakepit.PythonEnvironment.Command do
  @moduledoc """
  Runtime command to launch Python workers.

  * `:executable` - path to the binary spawned through `Port.open/2`.
  * `:args` - argument list applied before adapter-provided script/args.
  * `:env` - environment variables as `[{\"KEY\", \"VALUE\"}]`.
  * `:cwd` - working directory for the spawned command (host-side).
  * `:path_mappings` - list used to translate script paths into the target environment.
  * `:set_host_cwd?` - keep legacy behaviour of using the script directory as the working directory.
  * `:metadata` - optional free-form map for diagnostics.
  """

  @enforce_keys [:executable]
  defstruct executable: nil,
            args: [],
            env: [],
            cwd: nil,
            path_mappings: [],
            set_host_cwd?: true,
            metadata: %{}

  @type t :: %__MODULE__{
          executable: String.t(),
          args: [String.t()],
          env: [{String.t(), String.t()}],
          cwd: String.t() | nil,
          path_mappings: [map() | {String.t(), String.t()}],
          set_host_cwd?: boolean(),
          metadata: map()
        }

  @doc """
  Apply any configured path mappings to a script path. The first match wins.
  """
  @spec apply_path(t(), String.t() | nil) :: String.t() | nil
  def apply_path(_command, nil), do: nil

  def apply_path(%__MODULE__{path_mappings: mappings}, path) when mappings == [], do: path

  def apply_path(%__MODULE__{path_mappings: mappings}, path) do
    Enum.find_value(mappings, path, fn
      %{from: from, to: to} -> translate(path, from, to)
      {from, to} when is_binary(from) and is_binary(to) -> translate(path, from, to)
      _ -> nil
    end)
  end

  defp translate(path, from, to) do
    normalized_from = normalize_prefix(from)

    if String.starts_with?(path, normalized_from) do
      suffix = String.replace_prefix(path, normalized_from, "")
      Path.join(to, suffix)
    end
  end

  defp normalize_prefix(prefix) do
    case String.ends_with?(prefix, "/") do
      true -> prefix
      false -> prefix <> "/"
    end
  end
end
