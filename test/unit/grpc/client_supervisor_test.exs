defmodule Snakepit.GRPC.ClientSupervisorTest do
  use ExUnit.Case, async: true

  alias Snakepit.GRPC.ClientSupervisor

  test "normalizes already_started startup race to :ignore" do
    parent = self()

    started_pid =
      spawn(fn ->
        receive do
        end
      end)

    assert :ignore =
             ClientSupervisor.start_link(
               whereis_fun: fn _name -> nil end,
               start_fun: fn ->
                 send(parent, :start_fun_called)
                 {:error, {:already_started, started_pid}}
               end
             )

    assert_receive :start_fun_called, 100
    Process.exit(started_pid, :kill)
  end

  test "attempts start even when whereis reports running to avoid TOCTOU race" do
    parent = self()

    started_pid =
      spawn(fn ->
        receive do
        end
      end)

    assert :ignore =
             ClientSupervisor.start_link(
               whereis_fun: fn _name -> started_pid end,
               start_fun: fn ->
                 send(parent, :start_fun_called)
                 {:error, {:already_started, started_pid}}
               end
             )

    assert_receive :start_fun_called, 100
    Process.exit(started_pid, :kill)
  end
end
