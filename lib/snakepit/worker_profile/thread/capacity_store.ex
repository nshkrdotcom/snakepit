defmodule Snakepit.WorkerProfile.Thread.CapacityStore do
  @moduledoc false

  use GenServer
  alias Snakepit.Logger, as: SLog

  @table_name :snakepit_worker_capacity
  @log_category :worker

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :not_started}

      pid ->
        {:ok, pid}
    end
  end

  def track_worker(worker_pid, capacity) when is_pid(worker_pid) and capacity > 0 do
    safe_call(
      __MODULE__,
      {:track_worker, worker_pid, capacity},
      {:error, :capacity_store_unavailable}
    )
  end

  def track_worker(store_pid, worker_pid, capacity)
      when is_pid(store_pid) and is_pid(worker_pid) and capacity > 0 do
    safe_call(
      store_pid,
      {:track_worker, worker_pid, capacity},
      {:error, :capacity_store_unavailable}
    )
  end

  def untrack_worker(worker_pid) when is_pid(worker_pid) do
    safe_call(__MODULE__, {:untrack_worker, worker_pid}, {:error, :capacity_store_unavailable})
  end

  def untrack_worker(store_pid, worker_pid) when is_pid(store_pid) and is_pid(worker_pid) do
    safe_call(store_pid, {:untrack_worker, worker_pid}, {:error, :capacity_store_unavailable})
  end

  def check_and_increment_load(worker_pid) when is_pid(worker_pid) do
    safe_call(
      __MODULE__,
      {:check_and_increment_load, worker_pid},
      {:error, :capacity_store_unavailable}
    )
  end

  def check_and_increment_load(store_pid, worker_pid)
      when is_pid(store_pid) and is_pid(worker_pid) do
    safe_call(
      store_pid,
      {:check_and_increment_load, worker_pid},
      {:error, :capacity_store_unavailable}
    )
  end

  def decrement_load(worker_pid) when is_pid(worker_pid) do
    safe_call(__MODULE__, {:decrement_load, worker_pid}, 0)
  end

  def decrement_load(store_pid, worker_pid) when is_pid(store_pid) and is_pid(worker_pid) do
    safe_call(store_pid, {:decrement_load, worker_pid}, 0)
  end

  def get_capacity(worker_pid) when is_pid(worker_pid) do
    safe_call(__MODULE__, {:get_capacity, worker_pid}, 1)
  end

  def get_capacity(store_pid, worker_pid) when is_pid(store_pid) and is_pid(worker_pid) do
    safe_call(store_pid, {:get_capacity, worker_pid}, 1)
  end

  def get_load(worker_pid) when is_pid(worker_pid) do
    safe_call(__MODULE__, {:get_load, worker_pid}, 0)
  end

  def get_load(store_pid, worker_pid) when is_pid(store_pid) and is_pid(worker_pid) do
    safe_call(store_pid, {:get_load, worker_pid}, 0)
  end

  def table_name, do: @table_name

  ## Server callbacks

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table_name, [
        :set,
        :protected,
        :named_table,
        {:read_concurrency, true}
      ])

    SLog.debug(@log_category, "Thread capacity store started with ETS table #{inspect(table)}")

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:track_worker, worker_pid, capacity}, _from, state) do
    :ets.insert(state.table, {worker_pid, capacity, 0})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:untrack_worker, worker_pid}, _from, state) do
    :ets.delete(state.table, worker_pid)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:check_and_increment_load, worker_pid}, _from, state) do
    reply =
      case :ets.lookup(state.table, worker_pid) do
        [{^worker_pid, capacity, load}] when load < capacity ->
          :ets.insert(state.table, {worker_pid, capacity, load + 1})
          {:ok, capacity, load + 1}

        [{^worker_pid, capacity, load}] ->
          {:at_capacity, capacity, load}

        [] ->
          {:error, :unknown_worker}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:get_capacity, worker_pid}, _from, state) do
    capacity =
      case :ets.lookup(state.table, worker_pid) do
        [{^worker_pid, capacity, _load}] -> capacity
        [] -> 1
      end

    {:reply, capacity, state}
  end

  @impl true
  def handle_call({:get_load, worker_pid}, _from, state) do
    load =
      case :ets.lookup(state.table, worker_pid) do
        [{^worker_pid, _capacity, load}] -> load
        [] -> 0
      end

    {:reply, load, state}
  end

  @impl true
  def handle_call({:decrement_load, worker_pid}, _from, state) do
    new_load =
      case :ets.lookup(state.table, worker_pid) do
        [{^worker_pid, capacity, load}] when load > 0 ->
          :ets.insert(state.table, {worker_pid, capacity, load - 1})
          load - 1

        [{^worker_pid, capacity, _load}] ->
          :ets.insert(state.table, {worker_pid, capacity, 0})
          0

        [] ->
          0
      end

    {:reply, new_load, state}
  end

  defp safe_call(server, request, fallback) do
    GenServer.call(server, request)
  catch
    :exit, {:noproc, _} -> fallback
    :exit, {:shutdown, _} -> fallback
    :exit, {:normal, _} -> fallback
    :exit, _ -> fallback
  end
end
