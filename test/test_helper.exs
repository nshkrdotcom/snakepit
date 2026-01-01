# Ensure Supertester is available
Code.ensure_loaded?(Supertester.UnifiedTestFoundation) ||
  raise "Supertester not found. Run: mix deps.get"

# Test support files are automatically compiled by Mix

# Generic polling helper for OTP-correct assertions (no sleeps!)
defmodule TestHelpers do
  @doc """
  Poll until a condition is met, or timeout.
  This is OTP-correct: we poll for actual state, not guess based on time.

  ## Examples
      assert_eventually(fn -> ProcessRegistry.worker_count() == 2 end)
      assert_eventually(fn -> not SessionStore.session_exists?(id) end, timeout: 5_000)
  """
  def assert_eventually(condition_fn, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    interval = Keyword.get(opts, :interval, 50)
    deadline = System.monotonic_time(:millisecond) + timeout

    poll_until(condition_fn, deadline, interval)
  end

  defp poll_until(condition_fn, deadline, interval) do
    current = System.monotonic_time(:millisecond)

    if current >= deadline do
      raise "Timeout waiting for condition to become true"
    end

    if condition_fn.() do
      :ok
    else
      receive do
      after
        interval -> :ok
      end

      poll_until(condition_fn, deadline, interval)
    end
  end
end

# Helper for polling worker shutdown
defmodule TestHelperShutdown do
  def wait_for_worker_shutdown(beam_run_id, deadline) do
    current = System.monotonic_time(:millisecond)

    if current >= deadline do
      # Timeout - log warning but don't fail
      IO.puts(:stderr, "Warning: Workers did not shut down within timeout")
      :ok
    else
      case System.cmd("pgrep", ["-f", "grpc_server.py.*--snakepit-run-id #{beam_run_id}"],
             stderr_to_stdout: true
           ) do
        {"", 1} ->
          # All workers shut down
          :ok

        _ ->
          # Still workers running, wait and check again using receive timeout
          receive do
          after
            100 -> :ok
          end

          wait_for_worker_shutdown(beam_run_id, deadline)
      end
    end
  end
end

include_tags_from_args =
  System.argv()
  |> Enum.chunk_every(2, 1, :discard)
  |> Enum.reduce([], fn
    ["--include", tags], acc -> acc ++ String.split(tags, ",")
    ["--only", tags], acc -> acc ++ String.split(tags, ",")
    _pair, acc -> acc
  end)
  |> Enum.map(fn tag ->
    tag
    |> String.split(":", parts: 2)
    |> List.first()
  end)

serial_run? = Enum.any?(include_tags_from_args, &(&1 in ["python_integration", "performance"]))
python_integration_from_args = Enum.member?(include_tags_from_args, "python_integration")

exunit_opts = [exclude: [:performance, :python_integration, :slow]]
exunit_opts = if serial_run?, do: Keyword.put(exunit_opts, :max_cases, 1), else: exunit_opts

# Start ExUnit with performance tests excluded by default.
ExUnit.start(exunit_opts)

include_tags = ExUnit.configuration()[:include] || []

python_integration? =
  python_integration_from_args or Keyword.has_key?(include_tags, :python_integration)

if python_integration? do
  # Ensure Python deps are available before starting Snakepit for integration tests.
  :ok = Snakepit.Bootstrap.run(skip_mix_deps: true)
  Application.put_env(:snakepit, :env_doctor_module, Snakepit.EnvDoctor)

  venv_python = Path.join(File.cwd!(), ".venv/bin/python3")

  if not File.exists?(venv_python) do
    raise ".venv missing after bootstrap; expected #{venv_python}"
  end
else
  # Ensure env doctor is stubbed for unit tests (real doctor exercised via dedicated tests).
  Application.put_env(:snakepit, :env_doctor_module, Snakepit.Test.FakeDoctor)
  Snakepit.Test.FakeDoctor.reset()
end

# START THE APPLICATION FOR TESTS
# Most tests need the app running with pooling_enabled: false (config/test.exs default)
# Tests that need pooling or specific config should:
#   1. Stop the app in setup
#   2. Configure as needed
#   3. Restart the app
#   4. Restore env and restart in on_exit callback
#
# This approach gives us:
# - Fast startup for unit tests (no pool workers spawned)
# - Isolation for integration tests (they manage their own lifecycle)
# - Proper cleanup via after_suite
IO.puts("\n=== Starting Snakepit application for test suite ===")
Application.put_env(:tls_certificate_check, :log_level, :error)
Application.ensure_all_started(:tls_certificate_check)
{:ok, apps} = Application.ensure_all_started(:snakepit)
IO.puts("Started applications: #{inspect(apps)}")

# Ensure proper application shutdown after all tests complete
# CRITICAL: Must wait for ACTUAL completion, not just initiate shutdown
# See docs/20251226/test-harness-remediation/REMEDIATION_PLAN.md
ExUnit.after_suite(fn _results ->
  IO.puts("\n=== Shutting down Snakepit application after test suite ===")

  # Get beam_run_id BEFORE stopping application
  beam_run_id =
    try do
      Snakepit.Pool.ProcessRegistry.get_beam_run_id()
    catch
      _, _ -> nil
    end

  # Monitor the supervisor BEFORE stopping so we can wait for actual termination
  sup_pid = Process.whereis(Snakepit.Supervisor)
  sup_ref = if sup_pid && Process.alive?(sup_pid), do: Process.monitor(sup_pid)

  # Initiate application shutdown
  Application.stop(:snakepit)

  # Wait for supervisor to ACTUALLY terminate (not just initiate)
  # This prevents race conditions where after_suite returns while cleanup is still in progress
  if sup_ref do
    receive do
      {:DOWN, ^sup_ref, :process, ^sup_pid, _reason} ->
        IO.puts("✅ Supervisor terminated successfully")
    after
      10_000 ->
        IO.puts(:stderr, "⚠️ Timeout waiting for supervisor termination (10s)")
    end
  end

  # THEN wait for OS processes to clean up (workers may take time to exit)
  if beam_run_id do
    deadline = System.monotonic_time(:millisecond) + 5_000
    TestHelperShutdown.wait_for_worker_shutdown(beam_run_id, deadline)
  end

  :ok
end)
