defmodule Snakepit.Pool.AsyncTaskRefTest do
  use ExUnit.Case, async: true

  alias Snakepit.Pool

  test "late async task tracking message does not re-introduce completed ref" do
    ref = make_ref()

    state = %Pool{async_task_refs: MapSet.new()}

    assert {:noreply, after_completion} = Pool.handle_info({ref, :ok}, state)
    assert MapSet.member?(after_completion.async_task_refs, ref) == false

    assert {:noreply, after_late_track} =
             Pool.handle_info({:track_async_task_ref, ref}, after_completion)

    assert MapSet.member?(after_late_track.async_task_refs, ref) == false
  end
end
