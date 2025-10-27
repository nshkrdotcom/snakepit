defmodule Snakepit.PythonThreadLimitsTest do
  use Snakepit.TestCase, async: true

  alias Snakepit.PythonThreadLimits

  describe "resolve/1" do
    test "returns defaults when nil" do
      assert PythonThreadLimits.resolve(nil) == PythonThreadLimits.defaults()
    end

    test "merges partial overrides without losing defaults" do
      resolved = PythonThreadLimits.resolve(%{"omp" => 2, openblas: 8})

      assert resolved[:openblas] == 8
      assert resolved[:omp] == 2
      assert resolved[:mkl] == 1
      assert resolved[:numexpr] == 1
      assert resolved[:grpc_poll_threads] == 1
    end

    test "accepts keyword lists and string values" do
      resolved = PythonThreadLimits.resolve(omp: "4")

      assert resolved[:omp] == 4
      assert resolved[:openblas] == 1
    end

    test "ignores unknown keys and coerces invalid values to defaults" do
      resolved =
        PythonThreadLimits.resolve(%{
          lotus: 99,
          mkl: 0,
          numexpr: "not-a-number"
        })

      assert resolved[:mkl] == 1
      assert resolved[:numexpr] == 1
      refute Map.has_key?(resolved, :lotus)
    end
  end
end
