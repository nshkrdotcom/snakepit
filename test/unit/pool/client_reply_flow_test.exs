defmodule Snakepit.Pool.ClientReplyFlowTest do
  use ExUnit.Case, async: true

  alias Snakepit.Pool.ClientReply

  test "replies to live client and checks worker back in" do
    pool_name = :pool_a
    worker_id = "worker_a"
    from = {self(), make_ref()}
    client_pid = self()
    ref = Process.monitor(client_pid)

    :ok =
      ClientReply.reply_and_checkin(
        pool_name,
        worker_id,
        from,
        ref,
        client_pid,
        {:ok, :done},
        fn pool, worker -> send(self(), {:checkin, pool, worker}) end
      )

    tag = elem(from, 1)
    assert_receive {^tag, {:ok, :done}}, 100
    assert_receive {:checkin, :pool_a, "worker_a"}, 100
  end

  test "skips reply when client is already down and checks worker in" do
    pool_name = :pool_b
    worker_id = "worker_b"
    client_pid = spawn(fn -> :ok end)
    from = {client_pid, make_ref()}
    ref = Process.monitor(client_pid)
    tag = elem(from, 1)

    assert :ok =
             ClientReply.reply_and_checkin(
               pool_name,
               worker_id,
               from,
               ref,
               client_pid,
               {:ok, :done},
               fn pool, worker -> send(self(), {:checkin, pool, worker}) end
             )

    refute_receive {^tag, _reply}, 100
    assert_receive {:checkin, :pool_b, "worker_b"}, 100
  end

  test "monitor_client_status returns :alive when client is still running" do
    client_pid =
      spawn(fn ->
        receive do
        end
      end)

    ref = Process.monitor(client_pid)
    assert :alive = ClientReply.monitor_client_status(ref, client_pid)

    Process.demonitor(ref, [:flush])
    Process.exit(client_pid, :kill)
  end

  test "monitor_client_status returns down reason when DOWN is pending" do
    client_pid = spawn(fn -> :ok end)
    ref = Process.monitor(client_pid)

    assert_receive {:DOWN, ^ref, :process, ^client_pid, :normal}, 100
    send(self(), {:DOWN, ref, :process, client_pid, :normal})

    assert {:down, :normal} = ClientReply.monitor_client_status(ref, client_pid)
  end
end
