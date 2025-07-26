#!/usr/bin/env elixir

# Snakepit Bridge Test Runner
# 
# This script provides a unified way to run all bridge-related tests
# including unit tests, integration tests, and property-based tests.
#
# Usage:
#   mix run test/run_bridge_tests.exs [options]
#
# Options:
#   --all              Run all tests (default)
#   --unit             Run only unit tests
#   --integration      Run only integration tests
#   --property         Run only property-based tests
#   --performance      Include performance tests
#   --verbose          Show detailed output
#   --help             Show this help

defmodule BridgeTestRunner do
  def main(args) do
    options = parse_args(args)

    if options[:help] do
      show_help()
      System.halt(0)
    end

    IO.puts("\n🧪 Snakepit Bridge Test Runner")
    IO.puts("=" <> String.duplicate("=", 40))

    test_types = determine_test_types(options)
    env_vars = build_env_vars(options)

    results =
      Enum.map(test_types, fn {type, config} ->
        run_test_suite(type, config, env_vars, options)
      end)

    print_summary(results)

    if Enum.all?(results, fn {_, success, _} -> success end) do
      IO.puts("\n✅ All tests passed!")
      System.halt(0)
    else
      IO.puts("\n❌ Some tests failed!")
      System.halt(1)
    end
  end

  defp parse_args(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          all: :boolean,
          unit: :boolean,
          integration: :boolean,
          property: :boolean,
          performance: :boolean,
          verbose: :boolean,
          help: :boolean
        ]
      )

    # Default to all if no specific type is selected
    if not (opts[:unit] or opts[:integration] or opts[:property]) do
      Keyword.put(opts, :all, true)
    else
      opts
    end
  end

  defp determine_test_types(options) do
    types = []

    types =
      if options[:all] or options[:unit] do
        types ++
          [
            {:unit,
             %{
               files: [
                 "test/snakepit/bridge/serialization_test.exs",
                 "test/snakepit/bridge/variables/variable_test.exs",
                 "test/snakepit/bridge/variables/types_test.exs",
                 "test/snakepit/bridge/session_test.exs",
                 "test/snakepit/bridge/session_store_variables_test.exs",
                 "test/snakepit/grpc/bridge_server_test.exs"
               ],
               tags: []
             }}
          ]
      else
        types
      end

    types =
      if options[:all] or options[:integration] do
        types ++
          [
            {:integration,
             %{
               files: ["test/snakepit/bridge/session_integration_test.exs"],
               tags: [:integration]
             }}
          ]
      else
        types
      end

    types =
      if options[:all] or options[:property] do
        types ++
          [
            {:property,
             %{
               files: ["test/snakepit/bridge/property_test.exs"],
               tags: [:property]
             }}
          ]
      else
        types
      end

    # Add performance tag if requested
    Enum.map(types, fn {type, config} ->
      if options[:performance] do
        {type, Map.update!(config, :tags, &(&1 ++ [:performance]))}
      else
        {type, config}
      end
    end)
  end

  defp build_env_vars(options) do
    vars = %{}

    if options[:verbose] do
      Map.put(vars, "TRACE", "1")
    else
      vars
    end
  end

  defp run_test_suite(type, config, env_vars, options) do
    IO.puts("\n📋 Running #{type} tests...")

    # Build mix test command
    args = ["test", "--color"]

    # Add specific files or use tag filtering
    args =
      if config[:files] do
        args ++ config[:files]
      else
        args
      end

    # Add include tags
    args =
      if config[:tags] && length(config[:tags]) > 0 do
        Enum.reduce(config[:tags], args, fn tag, acc ->
          acc ++ ["--include", to_string(tag)]
        end)
      else
        args
      end

    # Exclude performance tests unless explicitly requested
    args =
      if not options[:performance] do
        args ++ ["--exclude", "performance"]
      else
        args
      end

    # Add verbosity
    args =
      if options[:verbose] do
        args ++ ["--trace"]
      else
        args
      end

    # Run the tests
    start_time = System.monotonic_time(:millisecond)

    {output, exit_code} =
      System.cmd("mix", args,
        into: if(options[:verbose], do: IO.stream(:stdio, :line), else: ""),
        env: env_vars
      )

    duration = System.monotonic_time(:millisecond) - start_time

    success = exit_code == 0

    if not options[:verbose] do
      if success do
        IO.puts("✅ #{type} tests passed (#{duration}ms)")
      else
        IO.puts("❌ #{type} tests failed (#{duration}ms)")
        IO.puts(output)
      end
    end

    {type, success, duration}
  end

  defp print_summary(results) do
    IO.puts("\n📊 Test Summary")
    IO.puts("-" <> String.duplicate("-", 40))

    total_duration =
      Enum.reduce(results, 0, fn {_, _, duration}, acc ->
        acc + duration
      end)

    Enum.each(results, fn {type, success, duration} ->
      status = if success, do: "✅ PASS", else: "❌ FAIL"
      type_str = type |> to_string() |> String.pad_trailing(15)
      IO.puts("#{type_str} #{status} (#{duration}ms)")
    end)

    IO.puts("-" <> String.duplicate("-", 40))
    IO.puts("Total time: #{total_duration}ms")
  end

  defp show_help do
    IO.puts("""
    Snakepit Bridge Test Runner

    Usage:
      mix run test/run_bridge_tests.exs [options]

    Options:
      --all              Run all tests (default)
      --unit             Run only unit tests
      --integration      Run only integration tests  
      --property         Run only property-based tests
      --performance      Include performance tests
      --verbose          Show detailed output
      --help             Show this help

    Examples:
      # Run all tests
      mix run test/run_bridge_tests.exs
      
      # Run only integration tests with verbose output
      mix run test/run_bridge_tests.exs --integration --verbose
      
      # Run unit and property tests
      mix run test/run_bridge_tests.exs --unit --property
      
      # Run all tests including performance
      mix run test/run_bridge_tests.exs --all --performance
    """)
  end
end

BridgeTestRunner.main(System.argv())
