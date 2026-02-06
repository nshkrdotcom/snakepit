defmodule Snakepit.Pool.ClientReply do
  @moduledoc false

  alias Snakepit.Logger, as: SLog

  @log_category :pool

  @spec reply_and_checkin(
          atom(),
          String.t() | nil,
          GenServer.from(),
          reference(),
          pid(),
          term(),
          (atom(), String.t() | nil -> term())
        ) :: :ok
  def reply_and_checkin(pool_name, worker_id, from, ref, client_pid, result, maybe_checkin_worker)
      when is_function(maybe_checkin_worker, 2) do
    case monitor_client_status(ref, client_pid) do
      {:down, _reason} ->
        SLog.warning(
          @log_category,
          "Client #{inspect(client_pid)} died before receiving reply. " <>
            "Checking in worker #{inspect(worker_id)}."
        )

        maybe_checkin_worker.(pool_name, worker_id)

      :alive ->
        Process.demonitor(ref, [:flush])
        GenServer.reply(from, result)
        maybe_checkin_worker.(pool_name, worker_id)
    end

    :ok
  end

  @spec monitor_client_status(reference(), pid()) :: :alive | {:down, term()}
  def monitor_client_status(ref, client_pid) when is_reference(ref) and is_pid(client_pid) do
    receive do
      {:DOWN, ^ref, :process, ^client_pid, reason} -> {:down, reason}
    after
      0 ->
        if Process.alive?(client_pid), do: :alive, else: {:down, :unknown}
    end
  end
end
