defmodule Snakepit.TestCase do
  @moduledoc """
  Base test case for all Snakepit tests.
  Provides Supertester integration and common helpers.
  """

  defmacro __using__(opts \\ []) do
    quote do
      use ExUnit.Case, async: unquote(Keyword.get(opts, :async, true))
      # TODO: Upgrade to :full_isolation after refactoring tests to use setup_isolated_genserver
      # Current tests use manual worker creation which conflicts with Supertester's cleanup
      use Supertester.UnifiedTestFoundation, isolation: :basic

      import Supertester.OTPHelpers
      import Supertester.GenServerHelpers
      import Supertester.Assertions
      import Snakepit.TestHelpers

      # Ensure clean application state
      setup_all do
        Application.ensure_all_started(:snakepit)
        :ok
      end
    end
  end
end
