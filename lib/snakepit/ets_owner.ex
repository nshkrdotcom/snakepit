defmodule Snakepit.ETSOwner do
  @moduledoc """
  Centralized owner of shared ETS tables used by Snakepit.

  ## Purpose

  ETS tables are linked to the process that creates them. If a short-lived
  process (like a Task) creates a table, the table is destroyed when that
  process exits. This module solves that problem by acting as a long-lived
  GenServer that owns all shared ETS tables for the Snakepit application.

  ## Managed Tables

  The following tables are managed by this module:

  - `:snakepit_worker_taints` - Tracks tainted workers in the crash barrier system.
    Used by `Snakepit.Worker.TaintRegistry` to prevent routing requests to
    workers that have recently crashed.

  - `:snakepit_zero_copy_handles` - Stores handles for zero-copy data transfers
    (DLPack, Arrow). Used by `Snakepit.ZeroCopy` to track active handles and
    their metadata.

  All tables are created with `read_concurrency: true` for optimal read
  performance in concurrent scenarios.

  ## Lifecycle

  This module is started as part of the base supervision tree (always started,
  regardless of `pooling_enabled` setting). Tables are created during `init/1`
  and persist for the lifetime of the application.

  ## Usage

  Consumer modules should call `ensure_table/1` to guarantee a table exists
  before accessing it:

      defp ensure_table do
        Snakepit.ETSOwner.ensure_table(:snakepit_worker_taints)
      end

  The function is idempotent - calling it multiple times is safe and efficient.

  ## Error Handling

  - Raises `ArgumentError` if an unknown table name is passed to `ensure_table/1`
  - Raises `RuntimeError` if called before the Snakepit application is started
  """

  use GenServer

  @typedoc """
  Known ETS table names managed by this module.
  """
  @type table_name :: :snakepit_worker_taints | :snakepit_zero_copy_handles

  # Registry of all managed tables with their creation options.
  # Keys are table names, values are ETS options passed to :ets.new/2.
  @tables %{
    snakepit_worker_taints: [:named_table, :set, :public, {:read_concurrency, true}],
    snakepit_zero_copy_handles: [:named_table, :set, :public, {:read_concurrency, true}]
  }

  @doc false
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Ensures the specified ETS table exists, creating it if necessary.

  This function is idempotent - if the table already exists, it returns
  immediately. If the table doesn't exist, it delegates creation to the
  ETSOwner GenServer to ensure proper ownership.

  ## Parameters

  - `table` - Atom name of the table. Must be one of the known tables
    registered in this module (`:snakepit_worker_taints` or
    `:snakepit_zero_copy_handles`).

  ## Returns

  The table name atom on success.

  ## Raises

  - `ArgumentError` - If the table name is not in the known registry
  - `RuntimeError` - If ETSOwner is not running (Snakepit not started)

  ## Examples

      iex> Snakepit.ETSOwner.ensure_table(:snakepit_worker_taints)
      :snakepit_worker_taints

      iex> Snakepit.ETSOwner.ensure_table(:unknown_table)
      ** (ArgumentError) unknown ETS table :unknown_table
  """
  @spec ensure_table(table_name()) :: table_name()
  def ensure_table(table) when is_atom(table) do
    opts = table_opts!(table)

    case :ets.whereis(table) do
      :undefined ->
        case Process.whereis(__MODULE__) do
          nil ->
            raise "Snakepit.ETSOwner not started; ensure the Snakepit application is running"

          pid when pid == self() ->
            create_table(table, opts)

          pid ->
            GenServer.call(pid, {:ensure_table, table})
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
  def handle_call({:ensure_table, table}, _from, state) do
    {:reply, create_table(table, table_opts!(table)), state}
  end

  defp create_table(table, opts) do
    case :ets.whereis(table) do
      :undefined ->
        try do
          :ets.new(table, opts)
        rescue
          error in ArgumentError ->
            case :ets.whereis(table) do
              :undefined ->
                reraise error, __STACKTRACE__

              _ ->
                table
            end
        end

        table

      _ ->
        table
    end
  end

  defp table_opts!(table) do
    case Map.fetch(@tables, table) do
      {:ok, opts} -> opts
      :error -> raise ArgumentError, "unknown ETS table #{inspect(table)}"
    end
  end
end
