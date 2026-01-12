defmodule Snakepit.SerializationTest do
  @moduledoc """
  Tests for Snakepit.Serialization module.

  These tests verify the Elixir-side helpers for detecting and inspecting
  unserializable markers created by the Python serialization layer.
  """
  use ExUnit.Case, async: true

  alias Snakepit.Serialization

  describe "unserializable?/1" do
    test "returns true for valid unserializable marker" do
      marker = %{
        "__ffi_unserializable__" => true,
        "__type__" => "module.ClassName",
        "__repr__" => "ClassName()"
      }

      assert Serialization.unserializable?(marker) == true
    end

    test "returns false for regular map" do
      assert Serialization.unserializable?(%{"key" => "value"}) == false
    end

    test "returns false for map with similar but wrong key" do
      assert Serialization.unserializable?(%{"__unserializable__" => true}) == false
    end

    test "returns false for map where marker is false" do
      marker = %{"__ffi_unserializable__" => false}
      assert Serialization.unserializable?(marker) == false
    end

    test "returns false for nil" do
      assert Serialization.unserializable?(nil) == false
    end

    test "returns false for string" do
      assert Serialization.unserializable?("string") == false
    end

    test "returns false for list" do
      assert Serialization.unserializable?([1, 2, 3]) == false
    end

    test "returns false for integer" do
      assert Serialization.unserializable?(42) == false
    end

    test "returns false for empty map" do
      assert Serialization.unserializable?(%{}) == false
    end

    test "works with string keys from JSON decoding" do
      # This is the typical case from actual Python return values
      marker = %{
        "__ffi_unserializable__" => true,
        "__type__" => "dspy.clients.lm.ModelResponse",
        "__repr__" => "ModelResponse(id='chatcmpl-123')"
      }

      assert Serialization.unserializable?(marker) == true
    end
  end

  describe "unserializable_info/1" do
    test "returns {:ok, info} for valid marker" do
      marker = %{
        "__ffi_unserializable__" => true,
        "__type__" => "dspy.clients.lm.ModelResponse",
        "__repr__" => "ModelResponse(id='chatcmpl-123')"
      }

      assert {:ok, info} = Serialization.unserializable_info(marker)
      assert info.type == "dspy.clients.lm.ModelResponse"
      assert info.repr == "ModelResponse(id='chatcmpl-123')"
    end

    test "returns :error for non-marker value" do
      assert Serialization.unserializable_info(%{"key" => "value"}) == :error
    end

    test "returns :error for nil" do
      assert Serialization.unserializable_info(nil) == :error
    end

    test "returns :error for string" do
      assert Serialization.unserializable_info("string") == :error
    end

    test "returns :error for list" do
      assert Serialization.unserializable_info([1, 2, 3]) == :error
    end

    test "returns :error for marker with false value" do
      marker = %{"__ffi_unserializable__" => false}
      assert Serialization.unserializable_info(marker) == :error
    end

    test "handles marker with missing optional fields" do
      # Minimal marker with just the required key
      marker = %{"__ffi_unserializable__" => true}

      assert {:ok, info} = Serialization.unserializable_info(marker)
      assert info.type == nil
      assert info.repr == nil
    end

    test "handles marker with only type field" do
      marker = %{
        "__ffi_unserializable__" => true,
        "__type__" => "some.Type"
      }

      assert {:ok, info} = Serialization.unserializable_info(marker)
      assert info.type == "some.Type"
      assert info.repr == nil
    end

    test "handles marker with only repr field" do
      marker = %{
        "__ffi_unserializable__" => true,
        "__repr__" => "SomeObject()"
      }

      assert {:ok, info} = Serialization.unserializable_info(marker)
      assert info.type == nil
      assert info.repr == "SomeObject()"
    end
  end

  describe "real-world scenarios" do
    test "detecting marker in DSPy history-like structure" do
      # Simulates what DSPex would receive from GLOBAL_HISTORY
      history_entry = %{
        "model" => "gpt-4",
        "cost" => 0.001,
        "messages" => [%{"role" => "user", "content" => "Hello"}],
        "outputs" => ["Hi there!"],
        "response" => %{
          "__ffi_unserializable__" => true,
          "__type__" => "dspy.clients.lm.ModelResponse",
          "__repr__" => "ModelResponse(id='chatcmpl-123', model='gpt-4')"
        }
      }

      # Serializable fields are normal maps
      refute Serialization.unserializable?(history_entry)
      refute Serialization.unserializable?(history_entry["messages"])

      # The response field is the marker
      assert Serialization.unserializable?(history_entry["response"])

      # Can extract info from the marker
      {:ok, info} = Serialization.unserializable_info(history_entry["response"])
      assert info.type == "dspy.clients.lm.ModelResponse"
      assert String.contains?(info.repr, "chatcmpl-123")
    end

    test "detecting markers in a list" do
      # A list with some unserializable items
      items = [
        1,
        "two",
        %{
          "__ffi_unserializable__" => true,
          "__type__" => "some.CustomObject",
          "__repr__" => "CustomObject()"
        },
        4
      ]

      results = Enum.map(items, &Serialization.unserializable?/1)
      assert results == [false, false, true, false]
    end
  end
end
