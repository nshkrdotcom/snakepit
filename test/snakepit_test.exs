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

  defmodule SlowPool do
    use GenServer

    def start_link(delay_ms) do
      GenServer.start_link(__MODULE__, delay_ms)
    end

    @impl true
    def init(delay_ms), do: {:ok, delay_ms}

    @impl true
    def handle_call({:execute, _command, _args, _opts}, _from, delay_ms) do
      Process.sleep(delay_ms)
      {:reply, {:ok, :late}, delay_ms}
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

  test "execute normalizes checkout worker_busy errors to Snakepit.Error" do
    {:ok, pool} = start_supervised({ErrorPool, {:error, :worker_busy}})

    assert {:error, %Snakepit.Error{category: :pool, details: details}} =
             Snakepit.execute("ping", %{}, pool: pool, timeout: 500)

    assert details.reason == :worker_busy
  end

  test "execute_in_session normalizes session_worker_unavailable errors to Snakepit.Error" do
    {:ok, pool} = start_supervised({ErrorPool, {:error, :session_worker_unavailable}})

    assert {:error, %Snakepit.Error{category: :pool, details: details}} =
             Snakepit.execute_in_session("session-1", "ping", %{}, pool: pool, timeout: 500)

    assert details.reason == :session_worker_unavailable
  end

  test "execute normalizes pool_saturated errors to Snakepit.Error" do
    {:ok, pool} = start_supervised({ErrorPool, {:error, :pool_saturated}})

    assert {:error, %Snakepit.Error{category: :pool, details: details}} =
             Snakepit.execute("ping", %{}, pool: pool, timeout: 500)

    assert details.reason == :pool_saturated
  end

  test "execute preserves requested pool_name in normalized error details" do
    {:ok, pool} = start_supervised({ErrorPool, {:error, :pool_not_initialized}})

    assert {:error, %Snakepit.Error{category: :pool, details: details}} =
             Snakepit.execute("ping", %{}, pool: pool, pool_name: :broken_pool, timeout: 500)

    assert details.reason == :pool_not_initialized
    assert details.pool_name == :broken_pool
  end

  test "execute normalizes queue timeout errors to Snakepit.Error timeout category" do
    {:ok, pool} = start_supervised({ErrorPool, {:error, :queue_timeout}})

    assert {:error, %Snakepit.Error{category: :timeout, details: details}} =
             Snakepit.execute("ping", %{}, pool: pool, timeout: 500)

    assert details.reason == :queue_timeout
  end

  test "execute timeout returns Snakepit.Error timeout contract" do
    {:ok, pool} = start_supervised({SlowPool, 200})

    assert {:error, %Snakepit.Error{category: :timeout, details: details}} =
             Snakepit.execute("ping", %{}, pool: pool, timeout: 25)

    assert details.command == "ping"
  end
end
