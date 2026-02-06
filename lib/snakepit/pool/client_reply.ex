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
    receive do
      {:DOWN, ^ref, :process, ^client_pid, _reason} ->
        SLog.warning(
          @log_category,
          "Client #{inspect(client_pid)} died before receiving reply. " <>
            "Checking in worker #{inspect(worker_id)}."
        )

        maybe_checkin_worker.(pool_name, worker_id)
    after
      0 ->
        Process.demonitor(ref, [:flush])
        GenServer.reply(from, result)
        maybe_checkin_worker.(pool_name, worker_id)
    end

    :ok
  end
end
