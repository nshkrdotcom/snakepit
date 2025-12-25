defmodule Mix.Tasks.Snakepit.Gen.Adapter do
  @moduledoc """
  Generate a Python adapter skeleton under priv/python.
  """

  use Mix.Task

  @shortdoc "Generate a Python adapter skeleton"

  @impl true
  def run(args) do
    name =
      case args do
        [value | _] -> value
        _ -> Mix.raise("Usage: mix snakepit.gen.adapter <adapter_name>")
      end

    adapter_dir = Path.join(["priv", "python", name])
    handler_dir = Path.join([adapter_dir, "handlers"])
    adapter_file = Path.join(adapter_dir, "adapter.py")
    init_file = Path.join(adapter_dir, "__init__.py")
    handler_init_file = Path.join(handler_dir, "__init__.py")

    if File.exists?(adapter_dir) do
      Mix.raise("Adapter directory already exists: #{adapter_dir}")
    end

    File.mkdir_p!(handler_dir)
    File.write!(init_file, "")
    File.write!(handler_init_file, "")
    File.write!(adapter_file, adapter_template(name))

    Mix.shell().info("✅ Adapter created at #{adapter_dir}")
    Mix.shell().info("Configure it with:")

    Mix.shell().info(~s(  adapter_args: ["--adapter", "#{name}.adapter.#{adapter_class(name)}"]))
  end

  defp adapter_class(name) do
    name
    |> Macro.camelize()
  end

  defp adapter_template(name) do
    class_name = adapter_class(name)

    """
    from snakepit_bridge.adapters.base import BaseAdapter, tool


    class #{class_name}(BaseAdapter):
        def __init__(self):
            super().__init__()

        @tool(description="Example tool - replace with your own")
        def example(self, payload: dict) -> dict:
            return {"ok": True, "payload": payload}
    """
  end
end
