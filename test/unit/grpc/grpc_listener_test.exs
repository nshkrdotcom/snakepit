defmodule Snakepit.GRPC.ListenerTest do
  use ExUnit.Case, async: false

  alias Snakepit.GRPC.Listener

  setup do
    Listener.clear_listener_info()
    on_exit(fn -> Listener.clear_listener_info() end)
    :ok
  end

  test "external pool selects the first available port" do
    test_pid = self()

    start_fun = fn _endpoint, port, _opts ->
      send(test_pid, {:attempt, port})

      if port == 50_052 do
        pid =
          spawn(fn ->
            receive do
              :stop -> :ok
            end
          end)

        {:ok, pid, port}
      else
        {:error, :eaddrinuse}
      end
    end

    config = %{
      mode: :external_pool,
      host: "localhost",
      bind_host: "127.0.0.1",
      base_port: 50_051,
      pool_size: 3
    }

    {:ok, pid} = start_link_with_config(config, start_fun)

    assert_receive {:attempt, 50_051}
    assert_receive {:attempt, 50_052}
    assert {:ok, info} = Listener.await_ready(500)
    assert info.port == 50_052
    assert Listener.address() == "localhost:50052"

    GenServer.stop(pid)
  end

  test "internal mode uses port 0 and publishes the assigned port" do
    test_pid = self()

    start_fun = fn _endpoint, port, _opts ->
      send(test_pid, {:attempt, port})

      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, pid, 45_321}
    end

    config = %{
      mode: :internal,
      host: "127.0.0.1",
      bind_host: "127.0.0.1"
    }

    {:ok, pid} = start_link_with_config(config, start_fun)

    assert_receive {:attempt, 0}
    assert {:ok, info} = Listener.await_ready(500)
    assert info.port == 45_321
    assert Listener.address() == "127.0.0.1:45321"

    GenServer.stop(pid)
  end

  defp start_link_with_config(config, start_fun) do
    Listener.start_link(config: config, start_fun: start_fun, name: nil)
  end
end
