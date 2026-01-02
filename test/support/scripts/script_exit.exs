defmodule Snakepit.Test.ScriptExitRunner do
  def main(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [
          exit_mode: :string,
          halt: :boolean,
          raise: :boolean,
          print_ready: :boolean
        ],
        aliases: [e: :exit_mode]
      )

    script_opts =
      []
      |> maybe_put_exit_mode(opts)
      |> maybe_put_halt(opts)

    if opts[:print_ready] do
      IO.puts("SCRIPT_READY")
    end

    Snakepit.run_as_script(
      fn ->
        if opts[:raise] do
          raise "boom"
        end

        :ok
      end,
      script_opts
    )
  end

  defp maybe_put_exit_mode(opts, parsed) do
    case parsed[:exit_mode] do
      nil -> opts
      value -> Keyword.put(opts, :exit_mode, String.to_atom(value))
    end
  end

  defp maybe_put_halt(opts, parsed) do
    if Keyword.has_key?(parsed, :halt) do
      Keyword.put(opts, :halt, parsed[:halt])
    else
      opts
    end
  end
end

Snakepit.Test.ScriptExitRunner.main(System.argv())
