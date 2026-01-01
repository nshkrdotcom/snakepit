defmodule Snakepit.CircuitBreaker do
  @moduledoc """
  Circuit breaker for Python worker fault tolerance.

  Implements the circuit breaker pattern to prevent cascading failures
  when workers are experiencing issues.

  ## States

  - `:closed` - Normal operation, all calls allowed
  - `:open` - Failure threshold exceeded, calls rejected
  - `:half_open` - Testing if service recovered, limited calls allowed

  ## Usage

      {:ok, cb} = CircuitBreaker.start_link(name: :my_cb, failure_threshold: 5)

      case CircuitBreaker.call(cb, fn -> risky_operation() end) do
        {:ok, result} -> handle_success(result)
        {:error, :circuit_open} -> handle_circuit_open()
        {:error, reason} -> handle_error(reason)
      end
  """

  use GenServer

  alias Snakepit.Defaults
  require Logger

  @type state :: :closed | :open | :half_open

  @type t :: %{
          state: state(),
          failure_count: non_neg_integer(),
          success_count: non_neg_integer(),
          failure_threshold: pos_integer(),
          reset_timeout_ms: pos_integer(),
          half_open_max_calls: pos_integer(),
          half_open_calls: non_neg_integer(),
          last_failure_time: integer() | nil,
          name: atom() | nil
        }

  # Client API

  @doc """
  Starts a circuit breaker.

  ## Options

  - `:name` - GenServer name (optional)
  - `:failure_threshold` - Number of failures before opening (default: 5)
  - `:reset_timeout_ms` - Time before transitioning to half-open (default: 30000)
  - `:half_open_max_calls` - Max calls allowed in half-open state (default: 1)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Returns the current circuit state.
  """
  @spec state(GenServer.server()) :: state()
  def state(server) do
    GenServer.call(server, :get_state)
  end

  @doc """
  Checks if a call is allowed through the circuit.
  """
  @spec allow_call?(GenServer.server()) :: boolean()
  def allow_call?(server) do
    GenServer.call(server, :allow_call?)
  end

  @doc """
  Records a successful call.
  """
  @spec record_success(GenServer.server()) :: :ok
  def record_success(server) do
    GenServer.cast(server, :record_success)
  end

  @doc """
  Records a failed call.
  """
  @spec record_failure(GenServer.server()) :: :ok
  def record_failure(server) do
    GenServer.cast(server, :record_failure)
  end

  @doc """
  Executes a function through the circuit breaker.

  Returns `{:error, :circuit_open}` if the circuit is open.
  """
  @spec call(GenServer.server(), (-> any())) :: any()
  def call(server, fun) do
    case GenServer.call(server, :try_call) do
      :allowed ->
        try do
          result = fun.()

          case result do
            {:ok, _} ->
              record_success(server)
              result

            {:error, _} ->
              record_failure(server)
              result

            other ->
              record_success(server)
              other
          end
        rescue
          e ->
            record_failure(server)
            reraise e, __STACKTRACE__
        catch
          kind, reason ->
            record_failure(server)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      :rejected ->
        {:error, :circuit_open}
    end
  end

  @doc """
  Returns circuit breaker statistics.
  """
  @spec stats(GenServer.server()) :: map()
  def stats(server) do
    GenServer.call(server, :get_stats)
  end

  @doc """
  Resets the circuit breaker to closed state.
  """
  @spec reset(GenServer.server()) :: :ok
  def reset(server) do
    GenServer.cast(server, :reset)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    state = %{
      state: :closed,
      failure_count: 0,
      success_count: 0,
      failure_threshold:
        Keyword.get(opts, :failure_threshold, Defaults.circuit_breaker_failure_threshold()),
      reset_timeout_ms:
        Keyword.get(opts, :reset_timeout_ms, Defaults.circuit_breaker_reset_timeout_ms()),
      half_open_max_calls:
        Keyword.get(opts, :half_open_max_calls, Defaults.circuit_breaker_half_open_max_calls()),
      half_open_calls: 0,
      last_failure_time: nil,
      name: Keyword.get(opts, :name)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    state = maybe_transition_to_half_open(state)
    {:reply, state.state, state}
  end

  def handle_call(:allow_call?, _from, state) do
    state = maybe_transition_to_half_open(state)

    allowed =
      case state.state do
        :closed -> true
        :half_open -> state.half_open_calls < state.half_open_max_calls
        :open -> false
      end

    {:reply, allowed, state}
  end

  def handle_call(:try_call, _from, state) do
    state = maybe_transition_to_half_open(state)

    case state.state do
      :closed ->
        {:reply, :allowed, state}

      :half_open ->
        if state.half_open_calls < state.half_open_max_calls do
          {:reply, :allowed, %{state | half_open_calls: state.half_open_calls + 1}}
        else
          {:reply, :rejected, state}
        end

      :open ->
        {:reply, :rejected, state}
    end
  end

  def handle_call(:get_stats, _from, state) do
    stats = %{
      state: state.state,
      failure_count: state.failure_count,
      success_count: state.success_count,
      failure_threshold: state.failure_threshold,
      half_open_calls: state.half_open_calls
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast(:record_success, state) do
    state = %{state | success_count: state.success_count + 1}

    state =
      case state.state do
        :half_open ->
          # Success in half-open transitions to closed
          emit_closed_event(state)
          %{state | state: :closed, failure_count: 0, half_open_calls: 0}

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_cast(:record_failure, state) do
    now = System.monotonic_time(:millisecond)
    state = %{state | failure_count: state.failure_count + 1, last_failure_time: now}

    state =
      case state.state do
        :closed ->
          if state.failure_count >= state.failure_threshold do
            emit_opened_event(state)
            %{state | state: :open}
          else
            state
          end

        :half_open ->
          # Failure in half-open transitions back to open
          emit_opened_event(state)
          %{state | state: :open, half_open_calls: 0}

        :open ->
          state
      end

    {:noreply, state}
  end

  def handle_cast(:reset, state) do
    emit_closed_event(state)

    {:noreply,
     %{
       state
       | state: :closed,
         failure_count: 0,
         half_open_calls: 0,
         last_failure_time: nil
     }}
  end

  # Private functions

  defp maybe_transition_to_half_open(%{state: :open} = state) do
    now = System.monotonic_time(:millisecond)

    if state.last_failure_time &&
         now - state.last_failure_time >= state.reset_timeout_ms do
      emit_half_open_event(state)
      %{state | state: :half_open, half_open_calls: 0}
    else
      state
    end
  end

  defp maybe_transition_to_half_open(state), do: state

  defp emit_opened_event(state) do
    :telemetry.execute(
      [:snakepit, :circuit_breaker, :opened],
      %{failure_count: state.failure_count},
      %{pool: state.name, reason: :failures}
    )
  end

  defp emit_closed_event(state) do
    :telemetry.execute(
      [:snakepit, :circuit_breaker, :closed],
      %{},
      %{pool: state.name}
    )
  end

  defp emit_half_open_event(state) do
    :telemetry.execute(
      [:snakepit, :circuit_breaker, :half_open],
      %{},
      %{pool: state.name}
    )
  end
end
