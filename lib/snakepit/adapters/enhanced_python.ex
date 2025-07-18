defmodule Snakepit.Adapters.EnhancedPython do
  @moduledoc """
  Enhanced Python adapter with dynamic method invocation capabilities.
  
  Extends the V2 bridge architecture to support universal Python interop
  while maintaining full backward compatibility with existing adapters.
  
  Features:
  - Dynamic method calls on any Python object/module
  - Object persistence across calls and sessions
  - Framework-agnostic design supporting any Python library
  - Automatic translation of legacy commands to dynamic calls
  - Smart serialization with framework-specific optimizations
  """
  
  @behaviour Snakepit.Adapter
  
  # Legacy commands from existing DSPy adapter
  @legacy_commands [
    "ping", "configure_lm", "create_program", "execute_program",
    "get_program", "list_programs", "delete_program", "clear_session"
  ]
  
  # New dynamic commands
  @dynamic_commands [
    "call", "store", "retrieve", "list_stored", "delete_stored", 
    "pipeline", "inspect"
  ]
  
  @impl true
  def executable_path do
    System.find_executable("python3") || System.find_executable("python")
  end
  
  @impl true
  def script_path do
    case :code.priv_dir(:snakepit) do
      {:error, :bad_name} ->
        Path.join([File.cwd!(), "priv", "python", "enhanced_bridge.py"])
      priv_dir ->
        Path.join(priv_dir, "python/enhanced_bridge.py")
    end
  end
  
  @impl true
  def script_args do
    ["--mode", "enhanced-worker"]
  end
  
  @impl true
  def supported_commands do
    @legacy_commands ++ @dynamic_commands
  end
  
  @impl true
  def validate_command(command, args) when command in @dynamic_commands do
    validate_dynamic_command(command, args)
  end
  
  def validate_command(command, args) when command in @legacy_commands do
    # Delegate to existing validation patterns
    validate_legacy_command(command, args)
  end
  
  def validate_command(command, _args) do
    {:error, "unsupported command '#{command}'. Supported: #{Enum.join(supported_commands(), ", ")}"}
  end
  
  @impl true
  def prepare_args(command, args) when command in @legacy_commands do
    # Transform legacy commands to dynamic calls
    translate_legacy_to_dynamic(command, args)
  end
  
  def prepare_args(command, args) when command in @dynamic_commands do
    # Pass through dynamic commands with standard preparation
    args |> stringify_keys() |> add_metadata(command)
  end
  
  @impl true
  def process_response(command, response) when command in @legacy_commands do
    # Process dynamic responses back to legacy format
    translate_dynamic_to_legacy(command, response)
  end
  
  def process_response(_command, response) do
    # Standard dynamic response processing
    case response do
      %{"status" => "ok"} = resp -> {:ok, resp}
      %{"status" => "error", "error" => error} -> {:error, error}
      other -> {:ok, other}
    end
  end
  
  # Translation functions (implementing backward compatibility)
  defp translate_legacy_to_dynamic("create_program", args) do
    program_id = get_field(args, "id")
    signature = get_field(args, "signature")
    
    %{
      "command" => "call",
      "target" => "dspy.Predict",
      "kwargs" => %{"signature" => convert_signature_to_dspy_format(signature)},
      "store_as" => program_id,
      "legacy_command" => "create_program"
    }
  end
  
  defp translate_legacy_to_dynamic("execute_program", args) do
    program_id = get_field(args, "program_id")
    inputs = get_field(args, "inputs")
    
    %{
      "command" => "call", 
      "target" => "stored.#{program_id}.__call__",
      "kwargs" => inputs,
      "legacy_command" => "execute_program"
    }
  end
  
  defp translate_legacy_to_dynamic("configure_lm", args) do
    %{
      "command" => "call",
      "target" => "dspy.configure", 
      "kwargs" => args,
      "legacy_command" => "configure_lm"
    }
  end
  
  defp translate_legacy_to_dynamic("get_program", args) do
    program_id = get_field(args, "program_id")
    
    %{
      "command" => "retrieve",
      "id" => program_id,
      "legacy_command" => "get_program"
    }
  end
  
  defp translate_legacy_to_dynamic("list_programs", _args) do
    %{
      "command" => "list_stored",
      "legacy_command" => "list_programs"
    }
  end
  
  defp translate_legacy_to_dynamic("delete_program", args) do
    program_id = get_field(args, "program_id")
    
    %{
      "command" => "delete_stored",
      "id" => program_id,
      "legacy_command" => "delete_program"
    }
  end
  
  defp translate_legacy_to_dynamic("clear_session", _args) do
    %{
      "command" => "call",
      "target" => "clear_all_stored",
      "kwargs" => %{},
      "legacy_command" => "clear_session"
    }
  end
  
  defp translate_legacy_to_dynamic("ping", args) do
    %{
      "command" => "ping",
      "kwargs" => args,
      "legacy_command" => "ping"
    }
  end
  
  defp translate_dynamic_to_legacy("create_program", response) do
    case response do
      %{"status" => "ok"} = resp ->
        {:ok, Map.put(resp, "message", "Program created successfully")}
      %{"status" => "error"} = resp ->
        {:error, resp["error"]}
      other ->
        {:ok, other}
    end
  end
  
  defp translate_dynamic_to_legacy("execute_program", response) do
    case response do
      %{"status" => "ok", "result" => result} ->
        outputs = extract_prediction_data(result)
        {:ok, %{"status" => "ok", "outputs" => outputs}}
      %{"status" => "error"} = resp ->
        {:error, resp["error"]}
      other ->
        {:ok, other}
    end
  end
  
  defp translate_dynamic_to_legacy("get_program", response) do
    case response do
      %{"status" => "ok", "object" => object} ->
        {:ok, %{"status" => "ok", "program" => object}}
      %{"status" => "error"} = resp ->
        {:error, resp["error"]}
      other ->
        {:ok, other}
    end
  end
  
  defp translate_dynamic_to_legacy("list_programs", response) do
    case response do
      %{"status" => "ok", "stored_objects" => objects} ->
        {:ok, %{"status" => "ok", "programs" => objects}}
      %{"status" => "error"} = resp ->
        {:error, resp["error"]}
      other ->
        {:ok, other}
    end
  end
  
  defp translate_dynamic_to_legacy(_command, response) do
    case response do
      %{"status" => "ok"} = resp -> {:ok, resp}
      %{"status" => "error", "error" => error} -> {:error, error}
      other -> {:ok, other}
    end
  end
  
  # Dynamic command validation
  defp validate_dynamic_command("call", args) do
    target = get_field(args, "target")
    if is_binary(target) and String.length(target) > 0 do
      :ok
    else
      {:error, "call command requires valid target string"}
    end
  end
  
  defp validate_dynamic_command("store", args) do
    id = get_field(args, "id")
    if is_binary(id) and String.length(id) > 0 do
      :ok
    else
      {:error, "store command requires valid id string"}
    end
  end
  
  defp validate_dynamic_command("retrieve", args) do
    id = get_field(args, "id")
    if is_binary(id) and String.length(id) > 0 do
      :ok
    else
      {:error, "retrieve command requires valid id string"}
    end
  end
  
  defp validate_dynamic_command("delete_stored", args) do
    id = get_field(args, "id")
    if is_binary(id) and String.length(id) > 0 do
      :ok
    else
      {:error, "delete_stored command requires valid id string"}
    end
  end
  
  defp validate_dynamic_command("pipeline", args) do
    steps = get_field(args, "steps")
    if is_list(steps) and length(steps) > 0 do
      :ok
    else
      {:error, "pipeline command requires valid steps list"}
    end
  end
  
  defp validate_dynamic_command("inspect", args) do
    target = get_field(args, "target")
    if is_binary(target) and String.length(target) > 0 do
      :ok
    else
      {:error, "inspect command requires valid target string"}
    end
  end
  
  defp validate_dynamic_command("list_stored", _args), do: :ok
  
  # Legacy command validation
  defp validate_legacy_command("ping", _args), do: :ok
  
  defp validate_legacy_command("configure_lm", args) do
    if is_map(args) do
      :ok
    else
      {:error, "configure_lm requires configuration map"}
    end
  end
  
  defp validate_legacy_command("create_program", args) do
    id = get_field(args, "id")
    signature = get_field(args, "signature")
    
    cond do
      not is_binary(id) or String.length(id) == 0 ->
        {:error, "create_program requires valid id string"}
      not signature ->
        {:error, "create_program requires signature"}
      true ->
        :ok
    end
  end
  
  defp validate_legacy_command("execute_program", args) do
    program_id = get_field(args, "program_id")
    
    if is_binary(program_id) and String.length(program_id) > 0 do
      :ok
    else
      {:error, "execute_program requires valid program_id string"}
    end
  end
  
  defp validate_legacy_command("get_program", args) do
    program_id = get_field(args, "program_id")
    
    if is_binary(program_id) and String.length(program_id) > 0 do
      :ok
    else
      {:error, "get_program requires valid program_id string"}
    end
  end
  
  defp validate_legacy_command("delete_program", args) do
    program_id = get_field(args, "program_id")
    
    if is_binary(program_id) and String.length(program_id) > 0 do
      :ok
    else
      {:error, "delete_program requires valid program_id string"}
    end
  end
  
  defp validate_legacy_command("list_programs", _args), do: :ok
  defp validate_legacy_command("clear_session", _args), do: :ok
  
  # Helper functions
  defp get_field(args, field) do
    args[field] || args[String.to_atom(field)]
  end
  
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end
  
  defp stringify_keys(list) when is_list(list) do
    Enum.map(list, &stringify_keys/1)
  end
  
  defp stringify_keys(value), do: value
  
  defp add_metadata(args, command) do
    Map.merge(args, %{
      "bridge_version" => "enhanced-v2",
      "command_type" => if command in @legacy_commands, do: "legacy", else: "dynamic",
      "timestamp" => System.system_time(:millisecond)
    })
  end
  
  defp convert_signature_to_dspy_format(signature) do
    cond do
      is_binary(signature) ->
        signature
      is_map(signature) ->
        inputs = Map.get(signature, "inputs", [])
        outputs = Map.get(signature, "outputs", [])
        
        input_names = Enum.map(inputs, fn
          %{"name" => name} -> name
          name when is_binary(name) -> name
          _ -> "input"
        end)
        
        output_names = Enum.map(outputs, fn
          %{"name" => name} -> name
          name when is_binary(name) -> name
          _ -> "output"
        end)
        
        input_str = Enum.join(input_names, ", ")
        output_str = Enum.join(output_names, ", ")
        
        "#{input_str} -> #{output_str}"
      true ->
        "input -> output"  # fallback
    end
  end
  
  defp extract_prediction_data(result) do
    case result do
      %{"prediction_data" => data} -> data
      %{"attributes" => attrs} -> 
        # Extract simple values from attributes
        attrs
        |> Enum.filter(fn {_k, v} -> 
          case v do
            %{"value" => val} when is_binary(val) or is_number(val) or is_boolean(val) -> true
            _ -> false
          end
        end)
        |> Enum.into(%{}, fn {k, %{"value" => v}} -> {k, v} end)
      %{"value" => value} -> value
      other -> other
    end
  end
end