#!/usr/bin/env elixir

# Graceful Serialization Demo
#
# Demonstrates how Snakepit handles non-JSON-serializable Python objects
# by converting them gracefully instead of failing.
#
# Run with: mix run --no-start examples/graceful_serialization.exs

Code.require_file("mix_bootstrap.exs", __DIR__)

Snakepit.Examples.Bootstrap.ensure_mix!([
  {:snakepit, path: "."}
])

# Configure Snakepit
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
Application.put_env(:snakepit, :pooling_enabled, true)

Application.put_env(:snakepit, :pools, [
  %{
    name: :default,
    worker_profile: :process,
    pool_size: 2,
    adapter_module: Snakepit.Adapters.GRPCPython
  }
])

Application.put_env(:snakepit, :pool_config, %{pool_size: 2})
Application.put_env(:snakepit, :grpc_listener, %{mode: :internal})
Snakepit.Examples.Bootstrap.ensure_grpc_port!()
Application.put_env(:snakepit, :log_level, :error)

defmodule GracefulSerializationDemo do
  @moduledoc """
  Demonstrates Snakepit's graceful serialization feature.

  Many Python libraries return objects that aren't directly JSON-serializable
  (datetime, custom classes, Pydantic models, etc.). Instead of failing,
  Snakepit:

  1. Tries common conversion methods (model_dump, to_dict, _asdict, tolist, isoformat)
  2. Falls back to a marker dict with type info for truly non-serializable objects

  This allows returning partial data even when some fields are non-serializable.
  """

  def run do
    IO.puts("\n=== Graceful Serialization Demo ===\n")
    IO.puts("Snakepit gracefully handles non-JSON-serializable Python objects.")
    IO.puts("Instead of failing, it converts them or adds informative markers.\n")

    demo_datetime()
    demo_convertible()
    demo_custom_class()
    demo_mixed_list()
    demo_complex()
    demo_all()

    IO.puts("\n=== Demo Complete ===")
    IO.puts("All non-serializable objects were handled gracefully!")
  end

  defp demo_datetime do
    IO.puts("--- Demo 1: datetime objects ---")
    IO.puts("Python datetime/date objects are converted via isoformat()")

    case Snakepit.execute("serialization_demo", %{demo_type: "datetime"}) do
      {:ok, result} ->
        datetime_demo = result["datetime_demo"]
        IO.puts("  datetime_now: #{datetime_demo["datetime_now"]} (ISO string)")
        IO.puts("  date_today: #{datetime_demo["date_today"]} (ISO string)")
        IO.puts("  preserved_string: #{datetime_demo["preserved_string"]}")
        IO.puts("  preserved_number: #{datetime_demo["preserved_number"]}")

      {:error, reason} ->
        IO.puts("  Error: #{inspect(reason)}")
    end

    IO.puts("")
  end

  defp demo_convertible do
    IO.puts("--- Demo 2: Objects with conversion methods ---")
    IO.puts("Objects with to_dict() or model_dump() are automatically converted")

    case Snakepit.execute("serialization_demo", %{demo_type: "convertible"}) do
      {:ok, result} ->
        convertible = result["convertible_demo"]
        api_response = convertible["api_response"]
        pydantic_like = convertible["pydantic_like"]

        IO.puts("  api_response (via to_dict): #{inspect(api_response)}")
        IO.puts("  pydantic_like (via model_dump): #{inspect(pydantic_like)}")

      {:error, reason} ->
        IO.puts("  Error: #{inspect(reason)}")
    end

    IO.puts("")
  end

  defp demo_custom_class do
    IO.puts("--- Demo 3: Custom classes without conversion methods ---")
    IO.puts("Non-convertible objects get a marker with type info")
    IO.puts("(By default, __repr__ is NOT included for security)")

    case Snakepit.execute("serialization_demo", %{demo_type: "custom"}) do
      {:ok, result} ->
        custom = result["custom_class_demo"]
        obj = custom["custom_object"]

        # Use the helper functions to safely inspect markers
        if Snakepit.Serialization.unserializable?(obj) do
          {:ok, info} = Snakepit.Serialization.unserializable_info(obj)
          IO.puts("  custom_object:")
          IO.puts("    marker detected: true")
          IO.puts("    type: #{info.type}")

          IO.puts(
            "    repr: #{info.repr || "(not included - set SNAKEPIT_UNSERIALIZABLE_DETAIL to enable)"}"
          )
        end

        IO.puts("  preserved_string: #{custom["preserved_string"]}")

        nested = custom["nested"]
        IO.puts("  nested.normal_value: #{nested["normal_value"]} (preserved)")
        IO.puts("  nested.another_custom: (also has marker)")

      {:error, reason} ->
        IO.puts("  Error: #{inspect(reason)}")
    end

    IO.puts("")
  end

  defp demo_mixed_list do
    IO.puts("--- Demo 4: Mixed list with various types ---")
    IO.puts("Lists containing both serializable and non-serializable items work")

    case Snakepit.execute("serialization_demo", %{demo_type: "mixed_list"}) do
      {:ok, result} ->
        list = result["mixed_list_demo"]

        list
        |> Enum.with_index()
        |> Enum.each(fn {item, idx} ->
          type_desc = describe_item(item)
          IO.puts("  [#{idx}] #{type_desc}")
        end)

      {:error, reason} ->
        IO.puts("  Error: #{inspect(reason)}")
    end

    IO.puts("")
  end

  defp demo_complex do
    IO.puts("--- Demo 5: Complex nested structures ---")
    IO.puts("Real applications return nested objects mixing serializable")
    IO.puts("and non-serializable data. All serializable data is preserved.\n")

    case Snakepit.execute("serialization_demo", %{demo_type: "complex"}) do
      {:ok, result} ->
        complex = result["complex_demo"]

        # QueryResult converts via to_dict()
        query_result = complex["result"]
        IO.puts("  result (via to_dict):")
        IO.puts("    value: #{query_result["value"]}")
        IO.puts("    score: #{query_result["score"]}")

        # ServiceResponse converts via model_dump()
        response = complex["latest_response"]
        IO.puts("\n  latest_response (via model_dump):")
        IO.puts("    id: #{response["id"]}")
        IO.puts("    data: #{inspect(response["data"])}")

        # InternalClient becomes marker (with redacted secret if repr enabled)
        client = complex["client"]

        if Snakepit.Serialization.unserializable?(client) do
          {:ok, info} = Snakepit.Serialization.unserializable_info(client)
          IO.puts("\n  client (marker - internal state not exposed):")
          IO.puts("    type: #{info.type}")

          if info.repr do
            IO.puts("    repr: #{info.repr}")
            IO.puts("    ^ Note: API key is REDACTED in repr_redacted_truncated mode")
          end
        end

        # RequestLog entries become markers
        logs = complex["logs"]
        IO.puts("\n  logs (#{length(logs)} entries, each becomes marker):")

        Enum.with_index(logs, 1)
        |> Enum.each(fn {entry, idx} ->
          if Snakepit.Serialization.unserializable?(entry) do
            {:ok, info} = Snakepit.Serialization.unserializable_info(entry)
            IO.puts("    [#{idx}] #{info.type}")
          end
        end)

        # Summary is plain data - always serializes
        summary = complex["summary"]
        IO.puts("\n  summary (plain data, always serializes):")
        IO.puts("    total_requests: #{summary["total_requests"]}")
        IO.puts("    request_ids: #{inspect(summary["request_ids"])}")

      {:error, reason} ->
        IO.puts("  Error: #{inspect(reason)}")
    end

    IO.puts("")
  end

  defp demo_all do
    IO.puts("--- Demo 6: Full structure (simulates real-world scenario) ---")
    IO.puts("Complex nested structures with mixed types serialize successfully")

    case Snakepit.execute("serialization_demo", %{demo_type: "all"}) do
      {:ok, result} ->
        IO.puts("  Result keys: #{inspect(Map.keys(result))}")
        IO.puts("  Total size: #{byte_size(inspect(result))} bytes")
        IO.puts("  All data preserved - no serialization failures!")

      {:error, reason} ->
        IO.puts("  Error: #{inspect(reason)}")
    end
  end

  defp describe_item(item) when is_integer(item), do: "#{item} (integer)"

  defp describe_item(item) when is_binary(item) do
    if String.match?(item, ~r/^\d{4}-\d{2}-\d{2}/) do
      "#{item} (datetime via isoformat)"
    else
      "\"#{item}\" (string)"
    end
  end

  defp describe_item(%{"__ffi_unserializable__" => true} = item) do
    type = item["__type__"] || "unknown"
    "<marker: #{type}>"
  end

  defp describe_item(%{"code" => _, "message" => _} = item) do
    "#{inspect(item)} (converted via to_dict)"
  end

  defp describe_item(item) when is_map(item), do: "#{inspect(item)} (dict)"
  defp describe_item(item), do: inspect(item)
end

Snakepit.run_as_script(
  fn ->
    GracefulSerializationDemo.run()
  end,
  halt: true
)
