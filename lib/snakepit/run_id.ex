defmodule Snakepit.RunID do
  @moduledoc """
  Generates short, unique BEAM run identifiers.

  Format: 7 characters, base36-encoded
  Components: timestamp (5 chars) + random (2 chars)
  Example: "k3x9a2p"

  These IDs are embedded in Python process command lines for reliable
  identification and cleanup across BEAM restarts.
  """

  @doc """
  Generates a unique 7-character run ID.

  ## Examples

      iex> run_id = Snakepit.RunID.generate()
      iex> String.length(run_id)
      7

      iex> run_id = Snakepit.RunID.generate()
      iex> Snakepit.RunID.valid?(run_id)
      true
  """
  def generate do
    # Use last 5 digits of microsecond timestamp (base36)
    # Cycles every ~60 million seconds (~2 years)
    timestamp = System.system_time(:microsecond)
    time_component = timestamp |> rem(60_466_176) |> Integer.to_string(36) |> String.downcase()
    time_part = String.pad_leading(time_component, 5, "0")

    # Add 2 random characters for collision resistance
    random_part =
      :rand.uniform(1296)
      |> Integer.to_string(36)
      |> String.downcase()
      |> String.pad_leading(2, "0")

    time_part <> random_part
  end

  @doc """
  Validates a run ID format.

  ## Examples

      iex> Snakepit.RunID.valid?("k3x9a2p")
      true

      iex> Snakepit.RunID.valid?("short")
      false

      iex> Snakepit.RunID.valid?("HAS-UPX")
      false
  """
  def valid?(run_id) when is_binary(run_id) do
    String.match?(run_id, ~r/^[0-9a-z]{7}$/)
  end

  def valid?(_), do: false

  @doc """
  Extracts run ID from a process command line.
  Supports both --snakepit-run-id and --run-id formats.

  ## Examples

      iex> cmd = "python3 grpc_server.py --snakepit-run-id k3x9a2p --port 50051"
      iex> Snakepit.RunID.extract_from_command(cmd)
      {:ok, "k3x9a2p"}

      iex> Snakepit.RunID.extract_from_command("no run id here")
      {:error, :not_found}
  """
  def extract_from_command(command) when is_binary(command) do
    # Try new format first (--run-id)
    case Regex.run(~r/--run-id\s+([0-9a-z]{7})/, command) do
      [_, run_id] ->
        {:ok, run_id}

      nil ->
        # Try old format (--snakepit-run-id) with 7-char short IDs
        case Regex.run(~r/--snakepit-run-id\s+([0-9a-z]{7})/, command) do
          [_, run_id] -> {:ok, run_id}
          nil -> {:error, :not_found}
        end
    end
  end

  def extract_from_command(_), do: {:error, :not_found}
end
