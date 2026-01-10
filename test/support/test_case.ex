defmodule Snakepit.TestCase do
  @moduledoc """
  Base test case for all Snakepit tests.
  Provides Supertester integration and common helpers.

  ## Usage

  For unit tests that don't need custom app config:

      defmodule MyTest do
        use Snakepit.TestCase
        # App is already started by test_helper.exs with pooling_enabled: false
      end

  For integration tests that need custom pooling config:

      defmodule MyIntegrationTest do
        use Snakepit.TestCase, async: false
        import Snakepit.TestHelpers

        setup do
          prev_pools = Application.get_env(:snakepit, :pools)
          prev_pooling = Application.get_env(:snakepit, :pooling_enabled)

          Application.stop(:snakepit)
          Application.load(:snakepit)

          on_exit(fn ->
            Application.stop(:snakepit)
            restore_env(:pools, prev_pools)
            restore_env(:pooling_enabled, prev_pooling)
            {:ok, _} = Application.ensure_all_started(:snakepit)
          end)

          :ok
        end

        defp restore_env(key, nil), do: Application.delete_env(:snakepit, key)
        defp restore_env(key, value), do: Application.put_env(:snakepit, key, value)
      end
  """

  defmacro __using__(opts \\ []) do
    async? = Keyword.get(opts, :async, true)
    isolation = Keyword.get(opts, :isolation, :basic)

    quote do
      use ExUnit.Case, async: unquote(async?)

      # NOTE: Using :basic isolation mode. Current tests use manual worker creation which
      # conflicts with Supertester's :full_isolation cleanup. This is a known limitation
      # and works as expected for the test suite.
      setup context do
        {:ok, base_context} =
          Supertester.UnifiedTestFoundation.setup_isolation(unquote(isolation), context)

        ensure_snakepit_started()

        {:ok, base_context}
      end

      defp ensure_snakepit_started do
        case Process.whereis(Snakepit.Supervisor) do
          nil ->
            {:ok, _} = Application.ensure_all_started(:snakepit)
            :ok

          _pid ->
            :ok
        end
      end

      import Supertester.OTPHelpers
      import Supertester.GenServerHelpers
      import Supertester.Assertions
      import Snakepit.TestHelpers

      # App is started by test_helper.exs - no need to start again here
      # Tests that need custom config should stop/restart in their own setup
    end
  end
end
