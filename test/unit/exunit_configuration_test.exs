defmodule Snakepit.ExUnitConfigurationTest do
  use ExUnit.Case, async: true

  test "python integration tests are excluded by default" do
    exclude_tags = ExUnit.configuration()[:exclude] || []
    assert :python_integration in exclude_tags
  end
end
