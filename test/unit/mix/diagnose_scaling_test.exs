defmodule MixDiagnoseScalingTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Diagnose.Scaling

  describe "count_established_from_lines/1" do
    test "counts ESTAB records in ss output" do
      lines = [
        "Netid  State   Recv-Q  Send-Q   Local Address:Port   Peer Address:Port",
        "tcp    ESTAB   0       0        127.0.0.1:50051      127.0.0.1:58000",
        "tcp    LISTEN  0       4096     0.0.0.0:22           0.0.0.0:*",
        "tcp    ESTAB   0       0        127.0.0.1:50052      127.0.0.1:58001"
      ]

      assert Scaling.count_established_from_lines(lines) == 2
    end
  end

  describe "filter_listener_lines/2" do
    test "returns only lines matching the requested ports" do
      lines = [
        "tcp    LISTEN 0      4096   0.0.0.0:22      0.0.0.0:*",
        "tcp    LISTEN 0      4096   0.0.0.0:50051   0.0.0.0:*",
        "tcp    LISTEN 0      4096   0.0.0.0:50052   0.0.0.0:*"
      ]

      result = Scaling.filter_listener_lines(lines, [50051])
      assert result == [Enum.at(lines, 1)]
    end
  end

  describe "measure_python_spawn/2" do
    test "aggregates successes and failures from a spawn function" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      spawn_fun = fn ->
        Agent.get_and_update(agent, fn count ->
          new_count = count + 1
          result = if new_count == 1, do: {:error, :boom}, else: :ok
          {result, new_count}
        end)
        |> case do
          {:error, reason} -> {:error, reason}
          _ -> :ok
        end
      end

      assert {:ok, %{results: results}} =
               Scaling.measure_python_spawn(3, spawn_fun)

      assert Enum.count(results, &(&1 == :ok)) == 2
      assert Enum.count(results, &match?({:error, _}, &1)) == 1
    end
  end
end
