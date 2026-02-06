defmodule Snakepit.Internal.Deprecation do
  @moduledoc false

  @table :snakepit_legacy_deprecation_usage
  @event [:snakepit, :deprecated, :module_used]

  @type option ::
          {:replacement, String.t()}
          | {:remove_after, String.t()}
          | {:status, :legacy_optional}
  @type options :: [option()]

  @spec emit_legacy_module_used(module(), options()) :: :ok
  def emit_legacy_module_used(module, opts) when is_atom(module) and is_list(opts) do
    ensure_table()

    if :ets.insert_new(@table, {module, true}) do
      :telemetry.execute(
        @event,
        %{count: 1},
        %{
          module: module,
          replacement: Keyword.get(opts, :replacement, "See module docs for replacement path"),
          remove_after: Keyword.get(opts, :remove_after, "v0.16.0"),
          status: Keyword.get(opts, :status, :legacy_optional)
        }
      )
    end

    :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [
            :named_table,
            :public,
            :set,
            {:read_concurrency, true},
            {:write_concurrency, true}
          ])
        rescue
          ArgumentError -> :ok
        end

      _tid ->
        :ok
    end
  end
end
