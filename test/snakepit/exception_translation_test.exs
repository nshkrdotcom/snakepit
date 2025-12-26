defmodule Snakepit.ExceptionTranslationTest do
  use ExUnit.Case, async: true

  alias Snakepit.Error.{PythonException, PythonTranslation, ValueError}

  test "maps known python exception types" do
    payload = %{
      "type" => "ValueError",
      "message" => "bad input",
      "stacktrace" => ["Traceback line 1\n", "Traceback line 2\n"],
      "context" => %{"library" => "numpy", "function" => "dot"}
    }

    encoded = Jason.encode!(payload)

    assert {:ok, %ValueError{} = error} = PythonTranslation.from_error_message(encoded)
    assert error.message == "bad input"
    assert error.context["library"] == "numpy"
    assert error.python_type == "ValueError"
    assert error.python_traceback =~ "Traceback line"
  end

  test "falls back to PythonException for unknown types" do
    payload = %{"type" => "WeirdError", "message" => "boom"}
    encoded = Jason.encode!(payload)

    assert {:ok, %PythonException{} = error} = PythonTranslation.from_error_message(encoded)
    assert error.python_type == "WeirdError"
    assert error.message == "boom"
  end
end
