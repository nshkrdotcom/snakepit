defmodule Mix.Tasks.Demo.Basic do
  @moduledoc """
  Run the basic load test demo with a configurable number of workers.
  
  ## Usage
  
      mix demo.basic [worker_count]
      
  ## Examples
  
      # Run with default 10 workers
      mix demo.basic
      
      # Run with 5 workers
      mix demo.basic 5
      
      # Run with 50 workers
      mix demo.basic 50
  """
  
  use Mix.Task
  
  @shortdoc "Run basic load test demo"
  
  @impl Mix.Task
  def run(args) do
    # Parse worker count from args
    worker_count = case args do
      [count_str] -> 
        case Integer.parse(count_str) do
          {count, ""} -> count
          _ -> 10
        end
      _ -> 10
    end
    
    # Start the application with custom configuration
    Mix.Task.run("app.start")
    
    # Run the demo
    SnakepitLoadtest.Demos.BasicLoadDemo.run(worker_count)
  end
end