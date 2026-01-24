defmodule Snakepit.ETSOwner do
  @moduledoc false

  use GenServer

  @tables [
    {:snakepit_worker_taints, [:named_table, :set, :public, {:read_concurrency, true}]},
    {:snakepit_zero_copy_handles, [:named_table, :set, :public, {:read_concurrency, true}]}
  ]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec ensure_table(atom(), list()) :: atom()
  def ensure_table(table, opts) when is_atom(table) and is_list(opts) do
    case :ets.whereis(table) do
      :undefined ->
        case Process.whereis(__MODULE__) do
          nil -> create_table(table, opts)
          pid when pid == self() -> create_table(table, opts)
          pid -> GenServer.call(pid, {:ensure_table, table, opts})
        end

      _ ->
        table
    end
  end

  @impl true
  def init(:ok) do
    Enum.each(@tables, fn {table, opts} -> create_table(table, opts) end)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:ensure_table, table, opts}, _from, state) do
    {:reply, create_table(table, opts), state}
  end

  defp create_table(table, opts) do
    case :ets.whereis(table) do
      :undefined ->
        try do
          :ets.new(table, opts)
        rescue
          ArgumentError -> table
        end

      _ ->
        table
    end
  end
end
