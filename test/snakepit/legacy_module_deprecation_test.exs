defmodule Snakepit.LegacyModuleDeprecationTest do
  use ExUnit.Case, async: false

  setup do
    handler_id = "snakepit-legacy-module-deprecation-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:snakepit, :deprecated, :module_used],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:legacy_module_deprecation, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    :ok
  end

  test "emits a deprecation event once per legacy module usage" do
    assert {:ok, "Thread-safe"} = Snakepit.Compatibility.check("numpy", :thread)

    assert_receive {:legacy_module_deprecation, [:snakepit, :deprecated, :module_used],
                    %{count: 1}, metadata},
                   1_000

    assert metadata.module == Snakepit.Compatibility
    assert metadata.status == :legacy_optional
    assert is_binary(metadata.replacement)
    assert is_binary(metadata.remove_after)

    assert {:ok, "Thread-safe"} = Snakepit.Compatibility.check("numpy", :thread)
    refute_receive {:legacy_module_deprecation, _, _, %{module: Snakepit.Compatibility}}, 200
  end

  test "different legacy modules each emit exactly once" do
    _ = Snakepit.Compatibility.list_all(:all)
    _ = Snakepit.PythonVersion.supports_free_threading?({3, 13, 0})

    assert_receive {:legacy_module_deprecation, _, _, %{module: Snakepit.Compatibility}}, 1_000

    assert_receive {:legacy_module_deprecation, _, _, %{module: Snakepit.PythonVersion}}, 1_000

    _ = Snakepit.PythonVersion.supports_free_threading?({3, 13, 0})
    refute_receive {:legacy_module_deprecation, _, _, %{module: Snakepit.PythonVersion}}, 200
  end
end
