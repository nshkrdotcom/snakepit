defmodule Snakepit.CompatibilityTest do
  use ExUnit.Case, async: true

  alias Snakepit.Compatibility

  describe "check/2" do
    test "returns :ok or warning for thread-safe libraries with thread profile" do
      # NumPy and SciPy are fully thread-safe
      assert :ok = Compatibility.check("numpy", :thread)
      assert :ok = Compatibility.check("scipy", :thread)

      # Torch is thread-safe but may return warning about configuration
      result = Compatibility.check("torch", :thread)
      assert result == :ok or match?({:warning, _}, result)
    end

    test "returns :ok for known libraries with process profile" do
      # Process profile isolates everything, always safe for known libraries
      assert :ok = Compatibility.check("numpy", :process)
      assert :ok = Compatibility.check("pandas", :process)
      assert :ok = Compatibility.check("matplotlib", :process)
    end

    test "returns unknown for unknown libraries" do
      # Unknown libraries return unknown even for process profile
      assert {:unknown, _} = Compatibility.check("unknown_library", :process)
      assert {:unknown, _} = Compatibility.check("unknown_library", :thread)
    end

    test "returns warning for thread-unsafe libraries with thread profile" do
      assert {:warning, msg} = Compatibility.check("pandas", :thread)
      assert String.contains?(msg, "not thread-safe")

      assert {:warning, msg} = Compatibility.check("matplotlib", :thread)
      assert String.contains?(msg, "not thread-safe")
    end

    test "returns warning for libraries requiring configuration" do
      # Libraries that are thread-safe but need configuration
      assert {:warning, msg} = Compatibility.check("torch", :thread)
      assert String.contains?(msg, "configuration")

      assert {:warning, msg} = Compatibility.check("scikit-learn", :thread)
      assert String.contains?(msg, "configuration")
    end

    test "returns unknown for untracked libraries" do
      assert {:unknown, msg} = Compatibility.check("some_random_library", :thread)
      assert String.contains?(msg, "unknown")
    end
  end

  describe "get_library_info/1" do
    test "returns info for known libraries" do
      assert {:ok, info} = Compatibility.get_library_info("numpy")
      assert info.thread_safe == true
      assert is_binary(info.notes)
      assert is_binary(info.recommendation)

      assert {:ok, info} = Compatibility.get_library_info("pandas")
      assert info.thread_safe == false
    end

    test "returns error for unknown libraries" do
      assert {:error, :not_found} = Compatibility.get_library_info("unknown_lib")
    end
  end

  describe "list_all/0" do
    test "returns libraries grouped by thread safety" do
      result = Compatibility.list_all()

      assert is_map(result)
      assert Map.has_key?(result, :thread_safe)
      assert Map.has_key?(result, :not_thread_safe)

      # Check that known libraries are in correct categories
      assert "numpy" in result.thread_safe
      assert "pandas" in result.not_thread_safe
    end

    test "all entries are sorted" do
      result = Compatibility.list_all()

      for {_category, libs} <- result do
        assert libs == Enum.sort(libs)
      end
    end
  end

  describe "generate_report/2" do
    test "categorizes libraries correctly for thread profile" do
      libraries = ["numpy", "pandas", "torch", "unknown_lib"]
      report = Compatibility.generate_report(libraries, :thread)

      assert is_list(report.compatible)
      assert is_list(report.warnings)
      assert is_list(report.unknown)

      # NumPy should be compatible (or in warnings if requires config)
      assert "numpy" in report.compatible or
               Enum.any?(report.warnings, fn {lib, _} -> lib == "numpy" end)

      # Pandas should have warning
      assert Enum.any?(report.warnings, fn {lib, _} -> lib == "pandas" end)

      # Unknown lib should be in unknown
      assert Enum.any?(report.unknown, fn {lib, _} -> lib == "unknown_lib" end)
    end

    test "all libraries compatible for process profile" do
      libraries = ["numpy", "pandas", "matplotlib"]
      report = Compatibility.generate_report(libraries, :process)

      # Process profile: everything goes in compatible (no warnings)
      assert report.compatible == libraries
      assert report.warnings == []
      assert report.unknown == []
    end
  end

  describe "check_python_version/2" do
    test "recommends thread-safe library with Python 3.13+" do
      assert :ok = Compatibility.check_python_version("numpy", {3, 13, 0})
      assert :ok = Compatibility.check_python_version("torch", {3, 14, 0})
    end

    test "warns about thread-unsafe library even with Python 3.13+" do
      assert {:warning, msg} = Compatibility.check_python_version("pandas", {3, 13, 0})
      assert String.contains?(msg, "not thread-safe")
    end

    test "warns about old Python version" do
      assert {:warning, msg} = Compatibility.check_python_version("numpy", {3, 12, 0})
      assert String.contains?(msg, "3.13+")
    end

    test "handles unknown libraries" do
      assert {:unknown, _} = Compatibility.check_python_version("unknown", {3, 13, 0})
    end
  end
end
