defmodule Snakepit.TestableGRPCWorker do
  @moduledoc """
  Test-only wrapper that adds Supertester.TestableGenServer to GRPCWorker.

  This is a minimal shim that just adds the __supertester_sync__ handler
  while delegating everything else to the real GRPCWorker implementation.

  NOTE: This is NOT a full GenServer - it only exists to satisfy tests that
  need cast_and_sync/3 for deterministic async testing. In actual usage,
  tests should still use Snakepit.GRPCWorker as the module name.
  """

  use Supertester.TestableGenServer

  # This module exists solely to inject Supertester support into GRPCWorker tests.
  # Tests should reference Snakepit.GRPCWorker directly, not this module.
  # The Supertester macros will automatically add the __supertester_sync__ handler.
end
