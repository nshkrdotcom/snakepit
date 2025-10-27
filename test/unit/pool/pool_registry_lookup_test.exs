defmodule Snakepit.Pool.RegistryLookupTest do
  use ExUnit.Case, async: true

  alias Snakepit.Pool
  alias Snakepit.Pool.Registry, as: PoolRegistry

  setup do
    case start_supervised(PoolRegistry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  test "extract_pool_name_from_worker_id prefers registry metadata" do
    worker_id = "custom-grpc-worker-#{System.unique_integer([:positive])}"
    parent = self()

    pid =
      spawn(fn ->
        Registry.register(
          PoolRegistry,
          worker_id,
          %{worker_module: Snakepit.GRPCWorker, pool_name: :analytics}
        )

        send(parent, :registered)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :registered, 1_000
    result = Pool.extract_pool_name_from_worker_id(worker_id)
    assert :analytics == result
    send(pid, :stop)
  end

  test "falls back to default and logs when metadata missing" do
    worker_id = "unparseable-worker-id"

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :default == Pool.extract_pool_name_from_worker_id(worker_id)
      end)

    assert log =~ "Falling back to worker_id parsing"
    assert log =~ worker_id
  end
end
