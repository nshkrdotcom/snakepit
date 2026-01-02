defmodule Snakepit.ScriptStop do
  @moduledoc false

  @type stop_mode :: :if_started | :always | :never

  @stop_modes [:if_started, :always, :never]

  @spec resolve_stop_mode(keyword()) :: stop_mode()
  def resolve_stop_mode(opts) when is_list(opts) do
    validate_stop_mode!(Keyword.get(opts, :stop_mode, :if_started))
  end

  @spec stop_snakepit?(stop_mode(), boolean()) :: boolean()
  def stop_snakepit?(stop_mode, owned?) when is_boolean(owned?) do
    case validate_stop_mode!(stop_mode) do
      :always -> true
      :never -> false
      :if_started -> owned?
    end
  end

  defp validate_stop_mode!(stop_mode) when stop_mode in @stop_modes, do: stop_mode

  defp validate_stop_mode!(stop_mode) do
    raise ArgumentError,
          "invalid stop_mode #{inspect(stop_mode)}; expected one of #{inspect(@stop_modes)}"
  end
end
