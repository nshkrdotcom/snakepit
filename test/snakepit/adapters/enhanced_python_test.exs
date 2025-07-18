defmodule Snakepit.Adapters.EnhancedPythonTest do
  use ExUnit.Case, async: true
  
  alias Snakepit.Adapters.EnhancedPython
  
  describe "adapter configuration" do
    test "provides executable path" do
      path = EnhancedPython.executable_path()
      assert is_binary(path)
      assert String.contains?(path, "python")
    end
    
    test "provides script path" do
      path = EnhancedPython.script_path()
      assert is_binary(path)
      assert String.ends_with?(path, "enhanced_bridge.py")
    end
    
    test "provides script args" do
      args = EnhancedPython.script_args()
      assert args == ["--mode", "enhanced-worker"]
    end
    
    test "lists supported commands" do
      commands = EnhancedPython.supported_commands()
      
      # Legacy commands
      assert "ping" in commands
      assert "configure_lm" in commands
      assert "create_program" in commands
      assert "execute_program" in commands
      
      # Dynamic commands
      assert "call" in commands
      assert "store" in commands
      assert "retrieve" in commands
      assert "pipeline" in commands
      assert "inspect" in commands
    end
  end
  
  describe "command validation" do
    test "validates dynamic commands" do
      # Valid call command
      assert :ok == EnhancedPython.validate_command("call", %{"target" => "math.sqrt"})
      
      # Invalid call command - missing target
      assert {:error, _} = EnhancedPython.validate_command("call", %{})
      
      # Valid store command
      assert :ok == EnhancedPython.validate_command("store", %{"id" => "my_object"})
      
      # Invalid store command - missing id
      assert {:error, _} = EnhancedPython.validate_command("store", %{})
      
      # Valid pipeline command
      assert :ok == EnhancedPython.validate_command("pipeline", %{"steps" => [%{"target" => "math.sqrt"}]})
      
      # Invalid pipeline command - missing steps
      assert {:error, _} = EnhancedPython.validate_command("pipeline", %{})
    end
    
    test "validates legacy commands" do
      # Valid ping
      assert :ok == EnhancedPython.validate_command("ping", %{})
      
      # Valid configure_lm
      assert :ok == EnhancedPython.validate_command("configure_lm", %{"provider" => "openai"})
      
      # Valid create_program
      assert :ok == EnhancedPython.validate_command("create_program", %{
        "id" => "test_program",
        "signature" => "input -> output"
      })
      
      # Invalid create_program - missing id
      assert {:error, _} = EnhancedPython.validate_command("create_program", %{
        "signature" => "input -> output"
      })
      
      # Invalid create_program - missing signature
      assert {:error, _} = EnhancedPython.validate_command("create_program", %{
        "id" => "test_program"
      })
    end
    
    test "rejects unsupported commands" do
      assert {:error, message} = EnhancedPython.validate_command("unsupported_command", %{})
      assert String.contains?(message, "unsupported command")
    end
  end
  
  describe "argument preparation" do
    test "prepares dynamic command arguments" do
      args = %{"target" => "math.sqrt", "kwargs" => %{"x" => 16}}
      prepared = EnhancedPython.prepare_args("call", args)
      
      assert prepared["target"] == "math.sqrt"
      assert prepared["kwargs"] == %{"x" => 16}
      assert prepared["bridge_version"] == "enhanced-v2"
      assert prepared["command_type"] == "dynamic"
      assert is_integer(prepared["timestamp"])
    end
    
    test "translates legacy commands to dynamic" do
      # Test create_program translation
      args = %{"id" => "test_program", "signature" => "question -> answer"}
      prepared = EnhancedPython.prepare_args("create_program", args)
      
      assert prepared["command"] == "call"
      assert prepared["target"] == "dspy.Predict"
      assert prepared["store_as"] == "test_program"
      assert prepared["legacy_command"] == "create_program"
      assert prepared["kwargs"]["signature"] == "question -> answer"
    end
    
    test "translates execute_program to dynamic" do
      args = %{"program_id" => "my_program", "inputs" => %{"question" => "What is AI?"}}
      prepared = EnhancedPython.prepare_args("execute_program", args)
      
      assert prepared["command"] == "call"
      assert prepared["target"] == "stored.my_program.__call__"
      assert prepared["kwargs"] == %{"question" => "What is AI?"}
      assert prepared["legacy_command"] == "execute_program"
    end
    
    test "translates configure_lm to dynamic" do
      args = %{"provider" => "openai", "api_key" => "test_key"}
      prepared = EnhancedPython.prepare_args("configure_lm", args)
      
      assert prepared["command"] == "call"
      assert prepared["target"] == "dspy.configure"
      assert prepared["kwargs"] == %{"provider" => "openai", "api_key" => "test_key"}
      assert prepared["legacy_command"] == "configure_lm"
    end
  end
  
  describe "response processing" do
    test "processes dynamic command responses" do
      # Success response
      response = %{"status" => "ok", "result" => %{"value" => 42}}
      assert {:ok, ^response} = EnhancedPython.process_response("call", response)
      
      # Error response
      error_response = %{"status" => "error", "error" => "Something went wrong"}
      assert {:error, "Something went wrong"} = EnhancedPython.process_response("call", error_response)
    end
    
    test "translates legacy responses" do
      # Test create_program response translation
      response = %{"status" => "ok", "stored_as" => "test_program"}
      {:ok, translated} = EnhancedPython.process_response("create_program", response)
      
      assert translated["status"] == "ok"
      assert translated["message"] == "Program created successfully"
      
      # Test execute_program response translation
      response = %{
        "status" => "ok", 
        "result" => %{
          "prediction_data" => %{"answer" => "AI is artificial intelligence"}
        }
      }
      {:ok, translated} = EnhancedPython.process_response("execute_program", response)
      
      assert translated["status"] == "ok"
      assert translated["outputs"]["answer"] == "AI is artificial intelligence"
    end
  end
  
  describe "signature conversion" do
    test "converts string signatures" do
      # String signature should pass through unchanged
      signature = "question -> answer"
      converted = EnhancedPython.convert_signature_to_dspy_format(signature)
      assert converted == signature
    end
    
    test "converts map signatures to DSPy format" do
      signature = %{
        "inputs" => [%{"name" => "question"}, %{"name" => "context"}],
        "outputs" => [%{"name" => "answer"}]
      }
      
      converted = EnhancedPython.convert_signature_to_dspy_format(signature)
      assert converted == "question, context -> answer"
    end
    
    test "handles simple list signatures" do
      signature = %{
        "inputs" => ["question", "context"],
        "outputs" => ["answer", "confidence"]
      }
      
      converted = EnhancedPython.convert_signature_to_dspy_format(signature)
      assert converted == "question, context -> answer, confidence"
    end
    
    test "provides fallback for invalid signatures" do
      converted = EnhancedPython.convert_signature_to_dspy_format(%{})
      assert converted == "input -> output"
      
      converted = EnhancedPython.convert_signature_to_dspy_format(nil)
      assert converted == "input -> output"
    end
  end
  
  describe "key stringification" do
    test "stringifies atom keys in maps" do
      input = %{
        atom_key: "value1",
        "string_key" => "value2",
        nested: %{
          inner_atom: "nested_value"
        }
      }
      
      result = EnhancedPython.stringify_keys(input)
      
      assert result["atom_key"] == "value1"
      assert result["string_key"] == "value2"
      assert result["nested"]["inner_atom"] == "nested_value"
      refute Map.has_key?(result, :atom_key)
    end
    
    test "stringifies keys in nested lists" do
      input = [
        %{atom_key: "value1"},
        %{another_atom: "value2"}
      ]
      
      result = EnhancedPython.stringify_keys(input)
      
      assert is_list(result)
      assert result[0]["atom_key"] == "value1"
      assert result[1]["another_atom"] == "value2"
    end
    
    test "handles non-map values" do
      assert EnhancedPython.stringify_keys("string") == "string"
      assert EnhancedPython.stringify_keys(42) == 42
      assert EnhancedPython.stringify_keys(true) == true
    end
  end
  
  describe "metadata addition" do
    test "adds metadata to arguments" do
      args = %{"key" => "value"}
      result = EnhancedPython.add_metadata(args, "call")
      
      assert result["key"] == "value"
      assert result["bridge_version"] == "enhanced-v2"
      assert result["command_type"] == "dynamic"
      assert is_integer(result["timestamp"])
    end
    
    test "identifies legacy commands correctly" do
      result = EnhancedPython.add_metadata(%{}, "ping")
      assert result["command_type"] == "legacy"
      
      result = EnhancedPython.add_metadata(%{}, "call")
      assert result["command_type"] == "dynamic"
    end
  end
end