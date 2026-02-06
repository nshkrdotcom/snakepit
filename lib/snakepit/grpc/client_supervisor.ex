defmodule Snakepit.GRPC.ClientSupervisor do
  @moduledoc false

  alias Snakepit.Logger, as: SLog

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]},
      type: :supervisor
    }
  end

  def start_link(opts \\ []) do
    whereis_fun = Keyword.get(opts, :whereis_fun, &Process.whereis/1)
    start_fun = Keyword.get(opts, :start_fun, &start_grpc_client_supervisor/0)

    case whereis_fun.(GRPC.Client.Supervisor) do
      nil ->
        normalize_start_result(start_fun.())

      _pid ->
        SLog.debug(:startup, "GRPC.Client.Supervisor already running; skipping start")
        :ignore
    end
  end

  defp start_grpc_client_supervisor do
    if Code.ensure_loaded?(GRPC.Client.Supervisor) and
         function_exported?(GRPC.Client.Supervisor, :start_link, 1) do
      SLog.debug(:startup, "Starting GRPC.Client.Supervisor module")
      apply(GRPC.Client.Supervisor, :start_link, [[]])
    else
      SLog.debug(:startup, "Starting DynamicSupervisor for GRPC.Client.Supervisor")
      DynamicSupervisor.start_link(name: GRPC.Client.Supervisor, strategy: :one_for_one)
    end
  end

  defp normalize_start_result({:error, {:already_started, _pid}}), do: :ignore
  defp normalize_start_result(result), do: result
end
