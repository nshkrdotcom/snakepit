#!/usr/bin/env elixir

# Enhanced Python Bridge - DSPy Integration Example
# 
# This script demonstrates using DSPy through the enhanced Python bridge
# with both legacy compatibility and new dynamic features.

# Configure Snakepit to use the enhanced Python adapter
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.EnhancedPython)
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{pool_size: 2})

# Start the application
{:ok, _} = Application.ensure_all_started(:snakepit)

IO.puts("=== DSPy Integration with Enhanced Python Bridge ===\n")

# Create a session for this workflow
session_id = Snakepit.Python.create_session()
IO.puts("Created session: #{session_id}\n")

# Step 1: Configure DSPy (you'll need to set your API key)
IO.puts("1. DSPy Configuration:")

api_key = System.get_env("GEMINI_API_KEY") || System.get_env("OPENAI_API_KEY")

if api_key do
  # Configure with Gemini (Google)
  if System.get_env("GEMINI_API_KEY") do
    case Snakepit.Python.configure_dspy(:gemini, %{
      model: "gemini-2.0-flash-exp",
      api_key: System.get_env("GEMINI_API_KEY")
    }, session_id: session_id) do
      {:ok, result} ->
        IO.puts("   ✓ DSPy configured with Gemini")
      {:error, error} ->
        IO.puts("   ✗ Error configuring DSPy: #{error}")
    end
  # Configure with OpenAI
  elsif System.get_env("OPENAI_API_KEY") do
    case Snakepit.Python.configure_dspy(:openai, %{
      model: "gpt-3.5-turbo",
      api_key: System.get_env("OPENAI_API_KEY")
    }, session_id: session_id) do
      {:ok, result} ->
        IO.puts("   ✓ DSPy configured with OpenAI")
      {:error, error} ->
        IO.puts("   ✗ Error configuring DSPy: #{error}")
    end
  end
else
  IO.puts("   ⚠ No API key found. Set GEMINI_API_KEY or OPENAI_API_KEY environment variable.")
  IO.puts("   Continuing with examples that don't require LM calls...")
end

IO.puts("")

# Step 2: Create DSPy programs using enhanced API
IO.puts("2. Creating DSPy Programs:")

# Simple Q&A program
case Snakepit.Python.create_dspy_program(:predict, %{
  signature: "question -> answer"
}, [store_as: "qa_program", session_id: session_id]) do
  {:ok, result} ->
    IO.puts("   ✓ Created Q&A program")
  {:error, error} ->
    IO.puts("   ✗ Error creating Q&A program: #{error}")
end

# Chain of Thought program
case Snakepit.Python.create_dspy_program(:chain_of_thought, %{
  signature: "context, question -> reasoning, answer"
}, [store_as: "cot_program", session_id: session_id]) do
  {:ok, result} ->
    IO.puts("   ✓ Created Chain of Thought program")
  {:error, error} ->
    IO.puts("   ✗ Error creating CoT program: #{error}")
end

IO.puts("")

# Step 3: Legacy compatibility demonstration
IO.puts("3. Legacy Compatibility:")

# Test legacy create_program command (should work through translation)
case Snakepit.execute_in_session(session_id, "create_program", %{
  id: "legacy_qa",
  signature: %{
    inputs: [%{name: "question"}],
    outputs: [%{name: "answer"}]
  }
}) do
  {:ok, result} ->
    IO.puts("   ✓ Legacy create_program works")
  {:error, error} ->
    IO.puts("   ✗ Error with legacy create_program: #{error}")
end

IO.puts("")

# Step 4: Advanced DSPy usage
IO.puts("4. Advanced DSPy Programs:")

# Create a more complex signature
case Snakepit.Python.call("dspy.Signature", %{
  signature: "context, question -> step_by_step_reasoning, final_answer",
  instructions: "Think step by step and provide detailed reasoning."
}, [store_as: "complex_signature", session_id: session_id]) do
  {:ok, result} ->
    IO.puts("   ✓ Created complex signature")
    
    # Use the signature with ChainOfThought
    case Snakepit.Python.call("dspy.ChainOfThought", %{
      signature: "stored.complex_signature"
    }, [store_as: "advanced_cot", session_id: session_id]) do
      {:ok, cot_result} ->
        IO.puts("   ✓ Created advanced Chain of Thought program")
      {:error, error} ->
        IO.puts("   ✗ Error creating advanced CoT: #{error}")
    end
    
  {:error, error} ->
    IO.puts("   ✗ Error creating complex signature: #{error}")
end

IO.puts("")

# Step 5: Program execution (if API key is available)
IO.puts("5. Program Execution:")

if api_key do
  # Execute the simple Q&A program
  case Snakepit.Python.execute_dspy("qa_program", %{
    question: "What is the capital of France?"
  }, session_id: session_id) do
    {:ok, result} ->
      IO.puts("   ✓ Q&A Program executed")
      if result["result"]["prediction_data"] do
        answer = result["result"]["prediction_data"]["answer"]
        IO.puts("     Answer: #{answer}")
      end
    {:error, error} ->
      IO.puts("   ✗ Error executing Q&A: #{error}")
  end
  
  # Execute Chain of Thought program
  case Snakepit.Python.execute_dspy("cot_program", %{
    context: "Paris is the largest city in France and serves as the country's political, cultural, and economic center.",
    question: "What role does Paris play in France?"
  }, session_id: session_id) do
    {:ok, result} ->
      IO.puts("   ✓ Chain of Thought executed")
      if result["result"]["prediction_data"] do
        reasoning = result["result"]["prediction_data"]["reasoning"]
        answer = result["result"]["prediction_data"]["answer"]
        IO.puts("     Reasoning: #{reasoning}")
        IO.puts("     Answer: #{answer}")
      end
    {:error, error} ->
      IO.puts("   ✗ Error executing CoT: #{error}")
  end
  
else
  IO.puts("   ⚠ Skipping execution - no API key available")
end

IO.puts("")

# Step 6: Pipeline with DSPy
IO.puts("6. DSPy Pipeline:")

dspy_pipeline = [
  # Create a summarization program
  {:call, "dspy.Predict", %{signature: "text -> summary"}, store_as: "summarizer"},
  
  # Create a sentiment analysis program
  {:call, "dspy.Predict", %{signature: "text -> sentiment"}, store_as: "sentiment_analyzer"},
]

case Snakepit.Python.pipeline(dspy_pipeline, session_id: session_id) do
  {:ok, result} ->
    IO.puts("   ✓ DSPy pipeline created: #{result["steps_completed"]} steps")
  {:error, error} ->
    IO.puts("   ✗ Pipeline error: #{error}")
end

if api_key do
  # Use the pipeline
  text_to_analyze = "I love using Elixir for building distributed systems. The actor model and fault tolerance make it perfect for real-time applications."
  
  # Summarize
  case Snakepit.Python.execute_dspy("summarizer", %{text: text_to_analyze}, session_id: session_id) do
    {:ok, result} ->
      IO.puts("   ✓ Text summarized")
      if result["result"]["prediction_data"] do
        summary = result["result"]["prediction_data"]["summary"]
        IO.puts("     Summary: #{summary}")
      end
    {:error, error} ->
      IO.puts("   ✗ Error summarizing: #{error}")
  end
  
  # Analyze sentiment
  case Snakepit.Python.execute_dspy("sentiment_analyzer", %{text: text_to_analyze}, session_id: session_id) do
    {:ok, result} ->
      IO.puts("   ✓ Sentiment analyzed")
      if result["result"]["prediction_data"] do
        sentiment = result["result"]["prediction_data"]["sentiment"]
        IO.puts("     Sentiment: #{sentiment}")
      end
    {:error, error} ->
      IO.puts("   ✗ Error analyzing sentiment: #{error}")
  end
end

IO.puts("")

# Step 7: Multi-step reasoning
IO.puts("7. Multi-step Reasoning:")

if api_key do
  # Create a complex reasoning pipeline
  reasoning_steps = [
    {:call, "stored.qa_program.__call__", %{question: "What are the benefits of functional programming?"}, store_as: "fp_benefits"},
    {:call, "stored.qa_program.__call__", %{question: "How does Elixir implement functional programming?"}, store_as: "elixir_fp"},
    {:call, "stored.qa_program.__call__", %{question: "What makes Elixir good for distributed systems?"}, store_as: "elixir_distributed"}
  ]
  
  case Snakepit.Python.pipeline(reasoning_steps, session_id: session_id) do
    {:ok, result} ->
      IO.puts("   ✓ Multi-step reasoning completed")
      results = result["pipeline_results"]
      
      questions = [
        "What are the benefits of functional programming?",
        "How does Elixir implement functional programming?",
        "What makes Elixir good for distributed systems?"
      ]
      
      Enum.zip(questions, results)
      |> Enum.with_index()
      |> Enum.each(fn {{question, step_result}, index} ->
        IO.puts("   Step #{index + 1}: #{question}")
        if step_result["result"]["prediction_data"] do
          answer = step_result["result"]["prediction_data"]["answer"]
          IO.puts("     Answer: #{String.slice(answer, 0, 100)}...")
        end
      end)
      
    {:error, error} ->
      IO.puts("   ✗ Multi-step reasoning error: #{error}")
  end
end

IO.puts("")

# Step 8: Inspect DSPy objects
IO.puts("8. DSPy Object Inspection:")

case Snakepit.Python.inspect("stored.qa_program", session_id: session_id) do
  {:ok, result} ->
    inspection = result["inspection"]
    IO.puts("   Q&A Program:")
    IO.puts("     Type: #{inspection["type"]}")
    IO.puts("     Module: #{inspection["module"]}")
    IO.puts("     Callable: #{inspection["callable"]}")
    if inspection["attributes"] do
      IO.puts("     Attributes: #{length(inspection["attributes"])}")
    end
  {:error, error} ->
    IO.puts("   ✗ Error inspecting Q&A program: #{error}")
end

# Inspect DSPy module itself
case Snakepit.Python.inspect("dspy", session_id: session_id) do
  {:ok, result} ->
    inspection = result["inspection"]
    IO.puts("   DSPy Module:")
    IO.puts("     Type: #{inspection["type"]}")
    if inspection["attributes"] do
      IO.puts("     Available functions/classes: #{length(inspection["attributes"])}")
    end
  {:error, error} ->
    IO.puts("   ✗ Error inspecting DSPy module: #{error}")
end

IO.puts("")

# Step 9: Session summary
IO.puts("9. Session Summary:")

case Snakepit.Python.list_stored(session_id: session_id) do
  {:ok, result} ->
    stored_objects = result["stored_objects"]
    IO.puts("   DSPy objects created:")
    
    dspy_objects = Enum.filter(stored_objects, fn obj_id ->
      String.contains?(obj_id, "program") or String.contains?(obj_id, "signature") or 
      String.contains?(obj_id, "cot") or String.contains?(obj_id, "qa") or
      String.contains?(obj_id, "summarizer") or String.contains?(obj_id, "sentiment")
    end)
    
    Enum.each(dspy_objects, fn object_id ->
      IO.puts("     - #{object_id}")
    end)
    
    IO.puts("   Total DSPy objects: #{length(dspy_objects)}")
    IO.puts("   Total session objects: #{length(stored_objects)}")
  {:error, error} ->
    IO.puts("   ✗ Error listing stored objects: #{error}")
end

IO.puts("")

# Step 10: Demonstrate legacy compatibility
IO.puts("10. Legacy Command Compatibility:")

# Test legacy list_programs (should work through translation)
case Snakepit.execute_in_session(session_id, "list_programs", %{}) do
  {:ok, result} ->
    programs = result["programs"] || result["stored_objects"]
    IO.puts("   ✓ Legacy list_programs works")
    IO.puts("     Found programs: #{inspect(programs)}")
  {:error, error} ->
    IO.puts("   ✗ Error with legacy list_programs: #{error}")
end

# Test legacy execute_program if we have programs
case Snakepit.execute_in_session(session_id, "execute_program", %{
  program_id: "legacy_qa",
  inputs: %{question: "What is 2+2?"}
}) do
  {:ok, result} ->
    IO.puts("   ✓ Legacy execute_program works")
    if result["outputs"] do
      IO.puts("     Outputs: #{inspect(result["outputs"])}")
    end
  {:error, error} ->
    IO.puts("   ✗ Error with legacy execute_program: #{error}")
end

IO.puts("\n=== DSPy Integration Complete ===")
IO.puts("Session ID: #{session_id}")

if not api_key do
  IO.puts("\n📝 Note: To test actual LM calls, set either:")
  IO.puts("   export GEMINI_API_KEY=your_gemini_api_key")
  IO.puts("   export OPENAI_API_KEY=your_openai_api_key")
end

IO.puts("\n=== Complete ===")