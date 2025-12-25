defmodule Snakepit.TestCase do
  @moduledoc """
  Base test case for all Snakepit tests.
  Provides Supertester integration and common helpers.
  """

  defmacro __using__(opts \\ []) do
    quote do
      # NOTE: Using :basic isolation mode. Current tests use manual worker creation which
      # conflicts with Supertester's :full_isolation cleanup. This is a known limitation
      # and works as expected for the test suite.
      use Supertester.ExUnitFoundation,
        isolation: :basic,
        async: unquote(Keyword.get(opts, :async, true))

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
