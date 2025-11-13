defmodule Snakepit.TestAdapters.QueueProbeAdapter do
  @moduledoc """
  Test-only adapter that wraps `Snakepit.TestAdapters.MockGRPCAdapter` and records
  how many slow probe commands actually executed.

  It drives the queue saturation experiments by:
    * Delegating all adapter callbacks to the mock adapter
    * Introducing the synthetic `"slow_probe"` command which maps to the mock
      `"slow_operation"` implementation with a configurable delay
    * Recording every executed request (by `request_id`) in an `Agent` that tests own

  The adapter is configured per-test via `configure/1` and cleaned up with `reset!/0`
  to ensure no persistent state leaks across suites.
  """

  @behaviour Snakepit.Adapter

  alias Snakepit.TestAdapters.MockGRPCAdapter, as: Mock
  alias MapSet

  @counter_key {:snakepit, :queue_probe_counter}
  @delay_key {:snakepit, :queue_probe_delay}

  @slow_probe_command "slow_probe"

  @doc """
  Configure the adapter for a given test run.

  ## Options
    * `:counter` - `Agent` PID that tracks execution metadata
    * `:delay` - millisecond delay injected into the synthetic slow command
  """
  def configure(opts) when is_list(opts) do
    if counter = Keyword.get(opts, :counter) do
      :persistent_term.put(@counter_key, counter)
    end

    delay = Keyword.get(opts, :delay, 500)
    :persistent_term.put(@delay_key, delay)
    :ok
  end

  @doc """
  Reset any previously stored configuration.
  """
  def reset! do
    :persistent_term.erase(@counter_key)
    :persistent_term.erase(@delay_key)
    :ok
  end

  # Adapter callbacks delegate to the mock implementation for everything except the
  # synthetic slow probe command.

  @impl true
  def executable_path, do: Mock.executable_path()

  @impl true
  def script_path, do: Mock.script_path()

  @impl true
  def script_args, do: Mock.script_args()

  @impl true
  def supported_commands do
    [@slow_probe_command | Mock.supported_commands()]
  end

  @impl true
  def validate_command(@slow_probe_command, _args), do: :ok
  def validate_command(command, args), do: Mock.validate_command(command, args)

  def get_port, do: Mock.get_port()

  def init_grpc_connection(port), do: Mock.init_grpc_connection(port)

  def uses_grpc?, do: Mock.uses_grpc?()

  def grpc_execute(connection, session_id, @slow_probe_command, args, timeout) do
    record_probe_execution(args)

    slow_args =
      args
      |> Map.put_new("delay", queue_delay())

    Mock.grpc_execute(connection, session_id, "slow_operation", slow_args, timeout)
  end

  def grpc_execute(connection, session_id, command, args, timeout) do
    Mock.grpc_execute(connection, session_id, command, args, timeout)
  end

  defp record_probe_execution(args) do
    case :persistent_term.get(@counter_key, nil) do
      nil ->
        :ok

      agent when is_pid(agent) ->
        request_id = Map.get(args, "request_id")

        Agent.update(agent, fn state ->
          state = state || %{}

          ids =
            state
            |> Map.get(:ids, MapSet.new())
            |> MapSet.put(request_id)

          count = Map.get(state, :count, 0) + 1
          Map.merge(state, %{count: count, ids: ids})
        end)
    end
  end

  defp queue_delay do
    case :persistent_term.get(@delay_key, nil) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 500
    end
  end
end
