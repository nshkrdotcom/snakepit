defmodule Snakepit.PythonVersionTest do
  use ExUnit.Case, async: true

  alias Snakepit.PythonVersion

  describe "detect/1" do
    test "detects Python version" do
      case PythonVersion.detect("python3") do
        {:ok, {major, minor, patch}} ->
          assert major == 3
          assert minor >= 8
          assert is_integer(patch)

        {:error, :python_not_found} ->
          # Python not installed, skip
          :ok
      end
    end

    test "handles version detection failure gracefully" do
      assert {:error, :python_not_found} = PythonVersion.detect("nonexistent_python")
    end
  end

  describe "supports_free_threading?/1" do
    test "returns true for Python 3.13+" do
      assert PythonVersion.supports_free_threading?({3, 13, 0}) == true
      assert PythonVersion.supports_free_threading?({3, 14, 0}) == true
      assert PythonVersion.supports_free_threading?({3, 15, 0}) == true
    end

    test "returns false for Python < 3.13" do
      assert PythonVersion.supports_free_threading?({3, 12, 0}) == false
      assert PythonVersion.supports_free_threading?({3, 11, 0}) == false
      assert PythonVersion.supports_free_threading?({3, 8, 0}) == false
    end

    test "returns false for Python 2.x" do
      assert PythonVersion.supports_free_threading?({2, 7, 18}) == false
    end
  end

  describe "recommend_profile/1" do
    test "recommends :thread for Python 3.13+" do
      assert PythonVersion.recommend_profile({3, 13, 0}) == :thread
      assert PythonVersion.recommend_profile({3, 14, 0}) == :thread
    end

    test "recommends :process for Python < 3.13" do
      assert PythonVersion.recommend_profile({3, 12, 0}) == :process
      assert PythonVersion.recommend_profile({3, 11, 0}) == :process
      assert PythonVersion.recommend_profile({3, 8, 0}) == :process
    end
  end

  describe "meets_requirements?/1" do
    test "returns true for Python 3.8+" do
      assert PythonVersion.meets_requirements?({3, 8, 0}) == true
      assert PythonVersion.meets_requirements?({3, 12, 0}) == true
      assert PythonVersion.meets_requirements?({3, 13, 0}) == true
    end

    test "returns false for Python < 3.8" do
      assert PythonVersion.meets_requirements?({3, 7, 0}) == false
      assert PythonVersion.meets_requirements?({3, 6, 0}) == false
      assert PythonVersion.meets_requirements?({2, 7, 18}) == false
    end
  end

  describe "get_info/1" do
    test "returns comprehensive version info" do
      # This test requires actual Python installation
      case PythonVersion.get_info() do
        {:ok, info} ->
          assert is_map(info)
          assert Map.has_key?(info, :version)
          assert Map.has_key?(info, :version_string)
          assert Map.has_key?(info, :supports_free_threading)
          assert Map.has_key?(info, :recommended_profile)
          assert Map.has_key?(info, :gil_status)

        {:error, :python_not_found} ->
          # Python not installed, skip
          :ok
      end
    end
  end

  describe "validate/0" do
    test "validates Python environment" do
      result = PythonVersion.validate()

      case result do
        :ok ->
          # Python meets requirements
          assert true

        {:warning, messages} ->
          # Python issues detected
          assert is_list(messages)
          assert length(messages) > 0
      end
    end
  end
end
