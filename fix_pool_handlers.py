#!/usr/bin/env python3
"""
Script to fix Pool.ex handlers for multi-pool support.
Replaces broken handlers that reference old state fields.
"""

import re

# Read the current Pool.ex
with open('/home/home/p/g/n/snakepit/lib/snakepit/pool/pool.ex', 'r') as f:
    content = f.read()

# Read the fixed handlers
with open('/home/home/p/g/n/snakepit/lib/snakepit/pool/pool_handlers_fix.ex', 'r') as f:
    fixes = f.read()

# Remove the header comment from fixes
fixes = re.sub(r'^#.*?\n\n', '', fixes, flags=re.DOTALL)

# Replace checkout_worker handler (lines 458-466)
old_checkout = r'''  def handle_call\(\{:checkout_worker, session_id\}, _from, state\) do
    case checkout_worker\(state, session_id\) do
      \{:ok, worker_id, new_state\} ->
        \{:reply, \{:ok, worker_id\}, new_state\}

      \{:error, :no_workers\} ->
        \{:reply, \{:error, :no_workers_available\}, state\}
    end
  end'''

new_checkout = '''  # checkout_worker - needs to route to default pool for backward compat
  def handle_call({:checkout_worker, session_id}, _from, state) do
    # Backward compat: use default pool
    pool_name = state.default_pool

    case Map.get(state.pools, pool_name) do
      nil ->
        {:reply, {:error, :pool_not_found}, state}

      pool_state ->
        case checkout_worker(pool_state, session_id) do
          {:ok, worker_id, new_pool_state} ->
            updated_pools = Map.put(state.pools, pool_name, new_pool_state)
            {:reply, {:ok, worker_id}, %{state | pools: updated_pools}}

          {:error, :no_workers} ->
            {:reply, {:error, :no_workers_available}, state}
        end
    end
  end'''

content = re.sub(old_checkout, new_checkout, content)

# Replace get_stats handler (lines 468-478)
old_get_stats = r'''  def handle_call\(:get_stats, _from, state\) do
    stats =
      Map\.merge\(state\.stats, %\{
        workers: length\(state\.workers\),
        available: MapSet\.size\(state\.available\),
        busy: map_size\(state\.busy\),
        queued: :queue\.len\(state\.request_queue\)
      \}\)

    \{:reply, stats, state\}
  end'''

new_get_stats = '''  # get_stats - aggregate stats from ALL pools (backward compat) or specific pool
  def handle_call(:get_stats, _from, state) do
    # Backward compat: aggregate stats from all pools
    aggregate_stats =
      Enum.reduce(state.pools, %{requests: 0, queued: 0, errors: 0, queue_timeouts: 0, pool_saturated: 0, workers: 0, available: 0, busy: 0}, fn {_name, pool}, acc ->
        %{
          requests: acc.requests + Map.get(pool.stats, :requests, 0),
          queued: acc.queued + Map.get(pool.stats, :queued, 0) + :queue.len(pool.request_queue),
          errors: acc.errors + Map.get(pool.stats, :errors, 0),
          queue_timeouts: acc.queue_timeouts + Map.get(pool.stats, :queue_timeouts, 0),
          pool_saturated: acc.pool_saturated + Map.get(pool.stats, :pool_saturated, 0),
          workers: acc.workers + length(pool.workers),
          available: acc.available + MapSet.size(pool.available),
          busy: acc.busy + map_size(pool.busy)
        }
      end)

    {:reply, aggregate_stats, state}
  end

  def handle_call({:get_stats, pool_name}, _from, state) do
    case Map.get(state.pools, pool_name) do
      nil ->
        {:reply, {:error, :pool_not_found}, state}

      pool_state ->
        stats =
          Map.merge(pool_state.stats, %{
            workers: length(pool_state.workers),
            available: MapSet.size(pool_state.available),
            busy: map_size(pool_state.busy),
            queued: :queue.len(pool_state.request_queue)
          })

        {:reply, stats, state}
    end
  end'''

content = re.sub(old_get_stats, new_get_stats, content)

# Replace list_workers handler (lines 480-482)
old_list_workers = r'''  def handle_call\(:list_workers, _from, state\) do
    \{:reply, state\.workers, state\}
  end'''

new_list_workers = '''  # list_workers - aggregate from ALL pools (backward compat) or specific pool
  def handle_call(:list_workers, _from, state) do
    # Backward compat: return workers from ALL pools
    all_workers =
      Enum.flat_map(state.pools, fn {_name, pool} ->
        pool.workers
      end)

    {:reply, all_workers, state}
  end

  def handle_call({:list_workers, pool_name}, _from, state) do
    case Map.get(state.pools, pool_name) do
      nil ->
        {:reply, {:error, :pool_not_found}, state}

      pool_state ->
        {:reply, pool_state.workers, state}
    end
  end'''

content = re.sub(old_list_workers, new_list_workers, content)

# Replace await_ready handler (lines 484-493)
old_await_ready = r'''  @impl true
  def handle_call\(:await_ready, from, state\) do
    if state\.initialized do
      \{:reply, :ok, state\}
    else
      # Pool is not ready yet, queue the caller to be replied to later
      new_waiters = \[from \| state\.initialization_waiters\]
      \{:noreply, %\{state \| initialization_waiters: new_waiters\}\}
    end
  end'''

new_await_ready = '''  # await_ready - wait for ALL pools (backward compat) or specific pool
  @impl true
  def handle_call(:await_ready, from, state) do
    # Backward compat: wait for ALL pools to be initialized
    all_initialized? =
      Enum.all?(state.pools, fn {_name, pool} -> pool.initialized end)

    if all_initialized? do
      {:reply, :ok, state}
    else
      # Add waiter to ALL uninitialized pools
      updated_pools =
        Enum.map(state.pools, fn {name, pool} ->
          if pool.initialized do
            {name, pool}
          else
            {name, %{pool | initialization_waiters: [from | pool.initialization_waiters]}}
          end
        end)
        |> Enum.into(%{})

      {:noreply, %{state | pools: updated_pools}}
    end
  end

  def handle_call({:await_ready, pool_name}, from, state) do
    case Map.get(state.pools, pool_name) do
      nil ->
        {:reply, {:error, :pool_not_found}, state}

      pool_state ->
        if pool_state.initialized do
          {:reply, :ok, state}
        else
          # Add waiter to this pool
          updated_pool = %{pool_state | initialization_waiters: [from | pool_state.initialization_waiters]}
          updated_pools = Map.put(state.pools, pool_name, updated_pool)
          {:noreply, %{state | pools: updated_pools}}
        end
    end
  end'''

content = re.sub(old_await_ready, new_await_ready, content)

# Write the updated content
with open('/home/home/p/g/n/snakepit/lib/snakepit/pool/pool.ex', 'w') as f:
    f.write(content)

print("Pool.ex handlers updated successfully!")
print("Fixed:")
print("- checkout_worker")
print("- get_stats")
print("- list_workers")
print("- await_ready")
