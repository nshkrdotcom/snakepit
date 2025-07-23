# Simple test script that only runs non-streaming demos

alias SnakepitShowcase.Demos.{
  BasicDemo,
  SessionDemo,
  VariablesDemo,
  BinaryDemo
}

IO.puts("\n=== Running Non-Streaming Demos ===\n")

demos = [
  {BasicDemo, "Basic Operations"},
  {SessionDemo, "Session Management"},
  {VariablesDemo, "Variable Management"},
  {BinaryDemo, "Binary Serialization"}
]

Enum.each(demos, fn {module, name} ->
  IO.puts("\n📋 Running: #{name}")
  IO.puts(String.duplicate("-", 40))
  
  try do
    case module.run() do
      :ok -> IO.puts("✅ #{name} completed successfully")
      {:error, reason} -> IO.puts("❌ #{name} failed: #{inspect(reason)}")
    end
  rescue
    e -> IO.puts("❌ #{name} crashed: #{inspect(e)}")
  end
  
  Process.sleep(500)
end)

IO.puts("\n=== Done ===")