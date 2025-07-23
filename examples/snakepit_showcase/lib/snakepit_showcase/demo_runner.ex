defmodule SnakepitShowcase.DemoRunner do
  @moduledoc """
  Orchestrates running various Snakepit demonstrations.
  """
  
  alias SnakepitShowcase.Demos.{
    BasicDemo,
    SessionDemo,
    StreamingDemo,
    ConcurrentDemo,
    VariablesDemo,
    BinaryDemo,
    MLWorkflowDemo
  }

  @demos [
    {BasicDemo, "Basic Operations"},
    {SessionDemo, "Session Management"},
    {StreamingDemo, "Streaming Operations"},
    {ConcurrentDemo, "Concurrent Processing"},
    {VariablesDemo, "Variable Management"},
    {BinaryDemo, "Binary Serialization"},
    {MLWorkflowDemo, "ML Workflows"}
  ]

  def run_all do
    IO.puts("\n🎯 Snakepit Showcase - Running All Demos\n")
    
    Enum.each(@demos, fn {module, name} ->
      IO.puts("\n" <> String.duplicate("=", 60))
      IO.puts("📋 Demo: #{name}")
      IO.puts(String.duplicate("=", 60) <> "\n")
      
      case module.run() do
        :ok -> IO.puts("✅ #{name} completed successfully")
        {:error, reason} -> IO.puts("❌ #{name} failed: #{inspect(reason)}")
      end
      
      Process.sleep(1000)
    end)
  end

  def interactive do
    IO.puts("\n🎯 Snakepit Showcase - Interactive Mode\n")
    main_menu()
  end

  defp main_menu do
    IO.puts("\nSelect a demo to run:")
    
    @demos
    |> Enum.with_index(1)
    |> Enum.each(fn {{_module, name}, idx} ->
      IO.puts("  #{idx}. #{name}")
    end)
    
    IO.puts("  0. Exit")
    
    case IO.gets("\nEnter your choice: ") |> String.trim() |> Integer.parse() do
      {0, _} -> 
        IO.puts("👋 Goodbye!")
        :ok
        
      {choice, _} when choice > 0 and choice <= length(@demos) ->
        {module, name} = Enum.at(@demos, choice - 1)
        run_demo(module, name)
        main_menu()
        
      _ ->
        IO.puts("❌ Invalid choice. Please try again.")
        main_menu()
    end
  end

  defp run_demo(module, name) do
    IO.puts("\n" <> String.duplicate("-", 40))
    IO.puts("🚀 Running: #{name}")
    IO.puts(String.duplicate("-", 40) <> "\n")
    
    module.run()
    
    IO.puts("\n✅ Demo completed. Press Enter to continue...")
    IO.gets("")
  end
end