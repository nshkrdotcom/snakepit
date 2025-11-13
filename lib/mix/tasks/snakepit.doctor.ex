defmodule Mix.Tasks.Snakepit.Doctor do
  @moduledoc """
  Diagnose the local Python and gRPC tooling required by Snakepit.
  """

  use Mix.Task

  @shortdoc "Run environment diagnostics for the Python bridge"

  @impl true
  def run(_args) do
    case Snakepit.EnvDoctor.run() do
      {:ok, results} ->
        Enum.each(results, &print_result/1)
        Mix.shell().info("✅ Snakepit environment is ready")
        :ok

      {:error, results} ->
        Enum.each(results, &print_result/1)
        Mix.raise("Snakepit environment checks failed. See messages above for remediation steps.")
    end
  end

  defp print_result(%{status: :ok, name: name, message: message}) do
    Mix.shell().info("✅ [#{format_name(name)}] #{message}")
  end

  defp print_result(%{status: :warning, name: name, message: message}) do
    Mix.shell().info("⚠️  [#{format_name(name)}] #{message}")
  end

  defp print_result(%{status: :error, name: name, message: message}) do
    Mix.shell().error("❌ [#{format_name(name)}] #{message}")
  end

  defp format_name(name) do
    name
    |> Atom.to_string()
    |> String.replace("_", " ")
  end
end
