defmodule ProcessRegistrySecurityTest do
  use ExUnit.Case, async: true

  alias Snakepit.Pool.ProcessRegistry

  test "dets table cannot be mutated without going through the registry" do
    assert_raise ArgumentError, fn ->
      :dets.insert(:snakepit_process_registry_dets, {"rogue_worker", %{}})
    end

    worker_id = "secure_worker_#{System.unique_integer([:positive])}"

    assert :ok = ProcessRegistry.reserve_worker(worker_id)

    elixir_pid = self()
    process_pid = 1234
    fingerprint = %{sha: "abc123"}

    assert :ok =
             ProcessRegistry.activate_worker(worker_id, elixir_pid, process_pid, fingerprint)

    assert {:ok, %{process_pid: ^process_pid}} =
             ProcessRegistry.get_worker_info(worker_id)

    ProcessRegistry.unregister_worker(worker_id)
  end
end
