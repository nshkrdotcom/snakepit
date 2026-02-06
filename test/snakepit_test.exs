defmodule SnakepitTest do
  use ExUnit.Case
  doctest Snakepit

  defmodule ErrorPool do
    use GenServer

    def start_link(reply) do
      GenServer.start_link(__MODULE__, reply)
    end

    @impl true
    def init(reply), do: {:ok, reply}

    @impl true
    def handle_call({:execute, _command, _args, _opts}, _from, reply) do
      {:reply, reply, reply}
    end
  end

  test "Snakepit module exists" do
    assert is_atom(Snakepit)
  end

  test "cleanup tolerates :noproc exits and remains idempotent" do
    assert :ok =
             Snakepit.cleanup(fn ->
               exit({:noproc, {GenServer, :call, [Snakepit.Pool.ProcessRegistry, :any]}})
             end)
  end

  test "execute preserves legacy atom errors from pool" do
    {:ok, pool} = start_supervised({ErrorPool, {:error, :worker_busy}})

    assert {:error, :worker_busy} =
             Snakepit.execute("ping", %{}, pool: pool, timeout: 500)
  end

  test "execute_in_session preserves legacy atom errors from pool" do
    {:ok, pool} = start_supervised({ErrorPool, {:error, :session_worker_unavailable}})

    assert {:error, :session_worker_unavailable} =
             Snakepit.execute_in_session("session-1", "ping", %{}, pool: pool, timeout: 500)
  end
end
