defmodule Snakepit.Adapters.GenericPythonV2Test do
  use ExUnit.Case, async: true

  alias Snakepit.Adapters.GenericPythonV2

  describe "adapter configuration" do
    test "executable_path returns python executable" do
      executable = GenericPythonV2.executable_path()

      assert executable in ["python3", "python"] or String.ends_with?(executable, "python3") or
               String.ends_with?(executable, "python")
    end

    test "script_path returns valid path" do
      script_path = GenericPythonV2.script_path()
      assert is_binary(script_path)

      # Should either be console script or development script
      assert String.ends_with?(script_path, "snakepit-generic-bridge") or
               String.ends_with?(script_path, "generic_bridge_v2.py")
    end

    test "script_args returns appropriate arguments" do
      args = GenericPythonV2.script_args()
      assert is_list(args)

      # Script args returns pool-worker mode and may include protocol
      assert "--mode" in args
      assert "pool-worker" in args

      # Check protocol configuration based on environment
      protocol_config = Application.get_env(:snakepit, :wire_protocol, :auto)

      case protocol_config do
        :json ->
          assert "--protocol" in args
          assert "json" in args

        :msgpack ->
          assert "--protocol" in args
          assert "msgpack" in args

        :auto ->
          # Auto mode doesn't pass protocol flag
          refute "--protocol" in args
      end
    end

    test "supported_commands returns expected commands" do
      commands = GenericPythonV2.supported_commands()
      assert commands == ["ping", "echo", "compute", "info"]
    end
  end

  describe "command validation" do
    test "ping command validation" do
      assert GenericPythonV2.validate_command("ping", %{}) == :ok
      assert GenericPythonV2.validate_command("ping", %{test: true}) == :ok
    end

    test "echo command validation" do
      assert GenericPythonV2.validate_command("echo", %{}) == :ok
      assert GenericPythonV2.validate_command("echo", %{message: "hello"}) == :ok
    end

    test "info command validation" do
      assert GenericPythonV2.validate_command("info", %{}) == :ok
    end

    test "compute command validation - valid operations" do
      valid_args = %{operation: "add", a: 5, b: 3}
      assert GenericPythonV2.validate_command("compute", valid_args) == :ok

      # Test with string keys
      valid_args_str = %{"operation" => "subtract", "a" => 10, "b" => 4}
      assert GenericPythonV2.validate_command("compute", valid_args_str) == :ok

      # Test all operations
      for op <- ["add", "subtract", "multiply", "divide"] do
        args = %{operation: op, a: 6, b: 2}
        assert GenericPythonV2.validate_command("compute", args) == :ok
      end
    end

    test "compute command validation - invalid operations" do
      # Invalid operation
      invalid_op = %{operation: "invalid", a: 5, b: 3}
      assert {:error, msg} = GenericPythonV2.validate_command("compute", invalid_op)
      assert msg =~ "operation must be one of"

      # Non-numeric arguments
      invalid_a = %{operation: "add", a: "not_number", b: 3}
      assert {:error, msg} = GenericPythonV2.validate_command("compute", invalid_a)
      assert msg =~ "parameter 'a' must be a number"

      invalid_b = %{operation: "add", a: 5, b: "not_number"}
      assert {:error, msg} = GenericPythonV2.validate_command("compute", invalid_b)
      assert msg =~ "parameter 'b' must be a number"

      # Division by zero
      div_zero = %{operation: "divide", a: 5, b: 0}
      assert {:error, msg} = GenericPythonV2.validate_command("compute", div_zero)
      assert msg =~ "division by zero is not allowed"
    end

    test "unsupported command validation" do
      assert {:error, msg} = GenericPythonV2.validate_command("unknown", %{})
      assert msg =~ "unsupported command 'unknown'"
      assert msg =~ "ping, echo, compute, info"
    end
  end

  describe "argument preparation" do
    test "prepare_args converts atom keys to strings" do
      args = %{operation: :add, a: 5, b: 3, nested: %{key: :value}}
      result = GenericPythonV2.prepare_args("compute", args)

      assert result == %{
               "operation" => :add,
               "a" => 5,
               "b" => 3,
               "nested" => %{"key" => :value}
             }
    end

    test "prepare_args handles string keys unchanged" do
      args = %{"operation" => "add", "a" => 5, "b" => 3}
      result = GenericPythonV2.prepare_args("compute", args)
      assert result == args
    end
  end

  describe "response processing" do
    test "process_response for successful compute" do
      response = %{
        "status" => "ok",
        "operation" => "add",
        "inputs" => %{"a" => 5, "b" => 3},
        "result" => 8,
        "timestamp" => 1_234_567_890
      }

      assert {:ok, ^response} = GenericPythonV2.process_response("compute", response)
    end

    test "process_response for failed compute" do
      response = %{
        "status" => "error",
        "error" => "Division by zero",
        "timestamp" => 1_234_567_890
      }

      assert {:error, msg} = GenericPythonV2.process_response("compute", response)
      assert msg == "computation failed: Division by zero"
    end

    test "process_response for other responses" do
      response = %{"some" => "data"}
      assert {:ok, ^response} = GenericPythonV2.process_response("compute", response)
    end

    test "process_response for non-compute commands" do
      response = %{
        "status" => "ok",
        "echoed" => %{"message" => "hello"},
        "timestamp" => 1_234_567_890
      }

      assert {:ok, ^response} = GenericPythonV2.process_response("echo", response)
    end
  end

  describe "package installation detection" do
    test "package_installed? returns boolean" do
      result = GenericPythonV2.package_installed?()
      assert is_boolean(result)
    end

    test "installation_instructions returns helpful text" do
      instructions = GenericPythonV2.installation_instructions()
      assert is_binary(instructions)
      assert instructions =~ "pip install"
      assert instructions =~ "priv/python"
      assert instructions =~ "snakepit-generic-bridge"
    end
  end

  describe "file existence checks" do
    test "development script file exists" do
      # Only test if we're in development mode
      unless GenericPythonV2.package_installed?() do
        script_path = GenericPythonV2.script_path()
        assert File.exists?(script_path), "Development script should exist at #{script_path}"
      end
    end

    test "package structure exists" do
      # Check that the new package structure exists
      priv_dir =
        case :code.priv_dir(:snakepit) do
          {:error, :bad_name} -> Path.join([File.cwd!(), "priv"])
          priv_dir -> priv_dir
        end

      package_dir = Path.join(priv_dir, "python/snakepit_bridge")
      assert File.exists?(package_dir), "Package directory should exist"

      init_file = Path.join(package_dir, "__init__.py")
      assert File.exists?(init_file), "Package __init__.py should exist"

      core_file = Path.join(package_dir, "core.py")
      assert File.exists?(core_file), "Core module should exist"

      adapters_dir = Path.join(package_dir, "adapters")
      assert File.exists?(adapters_dir), "Adapters directory should exist"

      generic_adapter = Path.join(adapters_dir, "generic.py")
      assert File.exists?(generic_adapter), "Generic adapter should exist"
    end
  end
end
