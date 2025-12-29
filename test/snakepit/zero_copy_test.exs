defmodule Snakepit.ZeroCopyTest do
  use ExUnit.Case, async: true

  import Snakepit.Logger.TestHelper

  alias Snakepit.ZeroCopy
  alias Snakepit.ZeroCopyRef

  setup do
    original = Application.get_env(:snakepit, :zero_copy)

    # Set up process-level log isolation
    setup_log_isolation()

    on_exit(fn ->
      Application.put_env(:snakepit, :zero_copy, original)
    end)

    :ok
  end

  test "exports and imports dlpack handles" do
    Application.put_env(:snakepit, :zero_copy, %{enabled: true, dlpack: true})

    payload = %{foo: "bar", list: [1, 2, 3]}
    assert {:ok, %ZeroCopyRef{kind: :dlpack} = ref} = ZeroCopy.to_dlpack(payload)
    assert {:ok, ^payload} = ZeroCopy.from_dlpack(ref)
    assert :ok = ZeroCopy.close(ref)
    assert {:error, :zero_copy_handle_not_found} = ZeroCopy.from_dlpack(ref)
  end

  test "falls back with warning when zero-copy is disabled" do
    Application.put_env(:snakepit, :zero_copy, %{enabled: false, allow_fallback: true})

    # Use process-level log level for isolation
    log =
      capture_at_level(:warning, fn ->
        assert {:ok, %ZeroCopyRef{copy: true}} = ZeroCopy.to_dlpack(%{value: 123})
      end)

    log = String.downcase(log)
    assert log =~ "zero-copy dlpack unavailable"
    assert log =~ "zero_copy_unavailable"
  end
end
