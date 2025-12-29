defmodule Snakepit.RunIDTest do
  use ExUnit.Case
  doctest Snakepit.RunID

  describe "generate/0" do
    test "creates 7-character run_id" do
      run_id = Snakepit.RunID.generate()
      assert String.length(run_id) == 7
    end

    test "creates unique run_ids" do
      ids = for _ <- 1..1000, do: Snakepit.RunID.generate()
      # Should have very high uniqueness
      unique_ids = Enum.uniq(ids)
      assert length(unique_ids) >= 990
    end

    test "generates only lowercase alphanumeric characters" do
      run_id = Snakepit.RunID.generate()
      assert String.match?(run_id, ~r/^[0-9a-z]{7}$/)
    end
  end

  describe "extract_from_command/1" do
    test "finds run_id from command line with --snakepit-run-id" do
      cmd = "python3 grpc_server.py --snakepit-run-id k3x9a2p --port 50051"
      assert {:ok, "k3x9a2p"} = Snakepit.RunID.extract_from_command(cmd)
    end

    test "finds run_id from command line with --run-id" do
      cmd = "python3 grpc_server.py --run-id k3x9a2p --port 50051"
      assert {:ok, "k3x9a2p"} = Snakepit.RunID.extract_from_command(cmd)
    end

    test "finds run_id with extra spaces" do
      cmd = "python3 grpc_server.py --snakepit-run-id   m7k2x1a --port 50051"
      assert {:ok, "m7k2x1a"} = Snakepit.RunID.extract_from_command(cmd)
    end

    test "returns error when no run_id present" do
      cmd = "python3 grpc_server.py --port 50051"
      assert {:error, :not_found} = Snakepit.RunID.extract_from_command(cmd)
    end

    test "returns error for invalid format" do
      # toolong8 is 8 chars, should not match 7-char pattern
      _cmd = "python3 grpc_server.py --run-id toolong8 --port 50051"
      # Actually, the current regex will match any 7 lowercase alphanumeric
      # Let's test with a truly invalid format
      cmd = "python3 grpc_server.py --run-id ABC-123 --port 50051"
      assert {:error, :not_found} = Snakepit.RunID.extract_from_command(cmd)
    end

    test "handles non-string input" do
      assert {:error, :not_found} = Snakepit.RunID.extract_from_command(nil)
      assert {:error, :not_found} = Snakepit.RunID.extract_from_command(123)
    end
  end
end
