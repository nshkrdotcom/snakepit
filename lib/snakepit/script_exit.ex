defmodule Snakepit.ScriptExit do
  @moduledoc false

  alias Snakepit.Logger, as: SLog

  @type exit_mode :: :none | :halt | :stop | :auto
  @type warning :: {:invalid_exit_env, String.t(), exit_mode()}

  @exit_modes [:none, :halt, :stop, :auto]
  @legacy_truthy ["1", "true", "yes", "y", "on"]

  @spec resolve_exit_mode(keyword(), map()) :: {exit_mode(), [warning()]}
  def resolve_exit_mode(opts, env) when is_list(opts) and is_map(env) do
    if Keyword.has_key?(opts, :exit_mode) do
      {validate_exit_mode!(Keyword.get(opts, :exit_mode)), []}
    else
      resolve_legacy_exit_mode(opts, env)
    end
  end

  @spec resolve_auto_exit_mode(exit_mode(), boolean()) :: exit_mode()
  def resolve_auto_exit_mode(:auto, owned?) do
    resolve_auto_exit_mode(:auto, owned?, no_halt?())
  end

  def resolve_auto_exit_mode(exit_mode, _owned?), do: exit_mode

  @spec resolve_auto_exit_mode(exit_mode(), boolean(), boolean()) :: exit_mode()
  def resolve_auto_exit_mode(:auto, true, true), do: :stop
  def resolve_auto_exit_mode(:auto, _owned?, _no_halt?), do: :none
  def resolve_auto_exit_mode(exit_mode, _owned?, _no_halt?), do: exit_mode

  @spec apply_exit_mode(exit_mode(), non_neg_integer()) :: :ok
  def apply_exit_mode(:none, _status), do: :ok

  def apply_exit_mode(:halt, status) when is_integer(status) do
    System.halt(status)
  end

  def apply_exit_mode(:stop, status) when is_integer(status) do
    System.stop(status)
    Process.sleep(:infinity)
  end

  @spec log_warnings([warning()]) :: :ok
  def log_warnings([]), do: :ok

  def log_warnings(warnings) when is_list(warnings) do
    Enum.each(warnings, &log_warning/1)
    :ok
  end

  @spec no_halt?() :: boolean()
  def no_halt? do
    match?({:ok, _}, :init.get_argument(:no_halt))
  end

  @spec parse_script_exit_env(String.t() | nil) ::
          {:ok, exit_mode()} | :unset | {:invalid, String.t()}
  def parse_script_exit_env(nil), do: :unset

  def parse_script_exit_env(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      :unset
    else
      case String.downcase(trimmed) do
        "none" -> {:ok, :none}
        "halt" -> {:ok, :halt}
        "stop" -> {:ok, :stop}
        "auto" -> {:ok, :auto}
        _ -> {:invalid, trimmed}
      end
    end
  end

  def parse_script_exit_env(_), do: :unset

  @spec legacy_halt_truthy?(String.t() | nil) :: boolean()
  def legacy_halt_truthy?(nil), do: false

  def legacy_halt_truthy?(value) when is_binary(value) do
    String.downcase(String.trim(value)) in @legacy_truthy
  end

  def legacy_halt_truthy?(_), do: false

  defp resolve_legacy_exit_mode(opts, env) do
    case Keyword.fetch(opts, :halt) do
      {:ok, true} ->
        {:halt, []}

      {:ok, false} ->
        resolve_env_exit_mode(env)

      :error ->
        resolve_env_exit_mode(env)
    end
  end

  defp resolve_env_exit_mode(env) do
    case parse_script_exit_env(Map.get(env, "SNAKEPIT_SCRIPT_EXIT")) do
      {:ok, exit_mode} ->
        {exit_mode, []}

      :unset ->
        resolve_legacy_halt_env(env)

      {:invalid, value} ->
        {fallback, _warnings} = resolve_legacy_halt_env(env)
        {fallback, [{:invalid_exit_env, value, fallback}]}
    end
  end

  defp resolve_legacy_halt_env(env) do
    if legacy_halt_truthy?(Map.get(env, "SNAKEPIT_SCRIPT_HALT")) do
      {:halt, []}
    else
      {:none, []}
    end
  end

  defp validate_exit_mode!(exit_mode) when exit_mode in @exit_modes, do: exit_mode

  defp validate_exit_mode!(exit_mode) do
    raise ArgumentError,
          "invalid exit_mode #{inspect(exit_mode)}; expected one of #{inspect(@exit_modes)}"
  end

  defp log_warning({:invalid_exit_env, value, fallback}) do
    SLog.warning(
      :shutdown,
      "Invalid SNAKEPIT_SCRIPT_EXIT value #{inspect(value)}; using exit_mode #{fallback}.",
      invalid_value: value,
      fallback_exit_mode: fallback
    )
  end
end
