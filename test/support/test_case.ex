defmodule Snakepit.TestCase do
  @moduledoc """
  Base test case for all Snakepit tests.
  Provides Supertester integration and common helpers.
  """

  defmacro __using__(opts \\ []) do
    quote do
      use ExUnit.Case, async: unquote(Keyword.get(opts, :async, true))
      use Supertester.UnifiedTestFoundation, isolation: :basic

      import Supertester.OTPHelpers
      import Supertester.GenServerHelpers
      import Supertester.Assertions
      import Snakepit.TestHelpers

      # Ensure clean application state
      setup_all do
        Application.ensure_all_started(:snakepit)
        on_exit(fn -> Snakepit.TestHelpers.cleanup_all_sessions() end)
      end
    end
  end
end
