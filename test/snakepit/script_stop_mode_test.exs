defmodule Snakepit.ScriptStopModeTest do
  use ExUnit.Case, async: false

  @shutdown_timeout 5_000

  setup do
    on_exit(fn ->
      Application.ensure_all_started(:snakepit)
    end)

    :ok
  end

  test "run_as_script keeps Snakepit running when already started" do
    {:ok, _apps} = Application.ensure_all_started(:snakepit)
    assert snakepit_started?()

    Snakepit.run_as_script(
      fn -> :ok end,
      exit_mode: :none,
      stop_mode: :if_started,
      await_pool: false
    )

    assert snakepit_started?()
  end

  test "run_as_script stops Snakepit when it started the app" do
    stop_snakepit!()
    refute snakepit_started?()

    Snakepit.run_as_script(
      fn -> :ok end,
      exit_mode: :none,
      stop_mode: :if_started,
      await_pool: false
    )

    refute snakepit_started?()
  end

  defp snakepit_started? do
    Enum.any?(Application.started_applications(), fn {app, _desc, _vsn} ->
      app == :snakepit
    end)
  end

  defp stop_snakepit! do
    case Process.whereis(Snakepit.Supervisor) do
      nil ->
        _ = Application.stop(:snakepit)
        :ok

      supervisor_pid ->
        ref = Process.monitor(supervisor_pid)
        _ = Application.stop(:snakepit)

        receive do
          {:DOWN, ^ref, :process, ^supervisor_pid, _reason} ->
            :ok
        after
          @shutdown_timeout ->
            flunk("timeout waiting for Snakepit supervisor shutdown")
        end
    end
  end
end
