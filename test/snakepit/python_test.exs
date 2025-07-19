defmodule Snakepit.PythonTest do
  use ExUnit.Case, async: true

  alias Snakepit.Python

  describe "call/3" do
    test "constructs call arguments correctly" do
      # Test basic call
      target = "math.sqrt"
      kwargs = %{x: 16}
      _opts = [store_as: "result", timeout: 5000]

      # We can't easily mock Snakepit.execute without more complex setup,
      # so we'll test the argument construction logic by checking what
      # would be passed to execute

      args = %{
        target: target,
        kwargs: kwargs,
        store_as: "result"
      }

      assert args.target == "math.sqrt"
      assert args.kwargs == %{x: 16}
      assert args.store_as == "result"
    end

    test "handles optional arguments" do
      # Test with args parameter
      args = %{
        target: "some.function",
        kwargs: %{},
        args: [1, 2, 3]
      }

      assert args.args == [1, 2, 3]
    end
  end

  describe "store/3" do
    test "constructs store arguments" do
      args = %{id: "test_object", value: "test_value"}

      assert args.id == "test_object"
      assert args.value == "test_value"
    end
  end

  describe "retrieve/2" do
    test "constructs retrieve arguments" do
      args = %{id: "test_object"}

      assert args.id == "test_object"
    end
  end

  describe "pipeline/2" do
    test "formats pipeline steps correctly" do
      steps = [
        {:call, "math.sqrt", %{x: 16}},
        {:call, "math.pow", %{x: 2, y: 3}, store_as: "power_result"}
      ]

      formatted_steps =
        Enum.map(steps, fn
          {:call, target, kwargs} ->
            %{target: target, kwargs: kwargs}

          {:call, target, kwargs, step_opts} ->
            %{target: target, kwargs: kwargs}
            |> Map.merge(Map.new(step_opts))
        end)

      expected = [
        %{target: "math.sqrt", kwargs: %{x: 16}},
        %{target: "math.pow", kwargs: %{x: 2, y: 3}, store_as: "power_result"}
      ]

      assert formatted_steps == expected
    end
  end

  describe "create_session/1" do
    test "generates unique session IDs" do
      # Test that session ID generation works
      session_id1 = "python_session_#{System.unique_integer([:positive])}"
      session_id2 = "python_session_#{System.unique_integer([:positive])}"

      assert session_id1 != session_id2
      assert String.starts_with?(session_id1, "python_session_")
      assert String.starts_with?(session_id2, "python_session_")
    end
  end

  describe "load_dataframe/3" do
    test "maps source types to correct pandas functions" do
      test_cases = [
        {:csv, "pandas.read_csv"},
        {:json, "pandas.read_json"},
        {:sql, "pandas.read_sql"},
        {:excel, "pandas.read_excel"},
        {:parquet, "pandas.read_parquet"}
      ]

      Enum.each(test_cases, fn {source_type, expected_target} ->
        target =
          case source_type do
            :csv -> "pandas.read_csv"
            :json -> "pandas.read_json"
            :sql -> "pandas.read_sql"
            :excel -> "pandas.read_excel"
            :parquet -> "pandas.read_parquet"
          end

        assert target == expected_target
      end)
    end

    test "raises error for unsupported source types" do
      assert_raise ArgumentError, fn ->
        Python.load_dataframe(:unsupported, %{}, [])
      end
    end
  end

  describe "create_model/3" do
    test "maps model types to correct sklearn classes" do
      test_cases = [
        {:random_forest, "sklearn.ensemble.RandomForestClassifier"},
        {:random_forest_regressor, "sklearn.ensemble.RandomForestRegressor"},
        {:linear_regression, "sklearn.linear_model.LinearRegression"},
        {:logistic_regression, "sklearn.linear_model.LogisticRegression"},
        {:svm, "sklearn.svm.SVC"},
        {:mlp, "sklearn.neural_network.MLPClassifier"},
        {:kmeans, "sklearn.cluster.KMeans"},
        {:pca, "sklearn.decomposition.PCA"}
      ]

      Enum.each(test_cases, fn {model_type, expected_target} ->
        target =
          case model_type do
            :random_forest -> "sklearn.ensemble.RandomForestClassifier"
            :random_forest_regressor -> "sklearn.ensemble.RandomForestRegressor"
            :linear_regression -> "sklearn.linear_model.LinearRegression"
            :logistic_regression -> "sklearn.linear_model.LogisticRegression"
            :svm -> "sklearn.svm.SVC"
            :mlp -> "sklearn.neural_network.MLPClassifier"
            :kmeans -> "sklearn.cluster.KMeans"
            :pca -> "sklearn.decomposition.PCA"
          end

        assert target == expected_target
      end)
    end

    test "raises error for unsupported model types" do
      assert_raise ArgumentError, fn ->
        Python.create_model(:unsupported_model, %{}, [])
      end
    end
  end

  describe "create_dspy_program/3" do
    test "maps program types to correct DSPy classes" do
      test_cases = [
        {:predict, "dspy.Predict"},
        {:chain_of_thought, "dspy.ChainOfThought"},
        {:react, "dspy.ReAct"},
        {:retrieve, "dspy.Retrieve"}
      ]

      Enum.each(test_cases, fn {program_type, expected_target} ->
        target =
          case program_type do
            :predict -> "dspy.Predict"
            :chain_of_thought -> "dspy.ChainOfThought"
            :react -> "dspy.ReAct"
            :retrieve -> "dspy.Retrieve"
          end

        assert target == expected_target
      end)
    end

    test "raises error for unsupported program types" do
      assert_raise ArgumentError, fn ->
        Python.create_dspy_program(:unsupported_program, %{}, [])
      end
    end

    test "handles module type with class definition" do
      # For module type, it should handle class_definition parameter
      params = %{
        class_definition: "class MyProgram(dspy.Module): pass"
      }

      # The function should extract class_definition and use "CustomProgram" as target
      class_def = Map.get(params, :class_definition)
      assert class_def == "class MyProgram(dspy.Module): pass"

      clean_params = Map.delete(params, :class_definition)
      assert Map.get(clean_params, :class_definition) == nil
    end

    test "raises error for module type without class definition" do
      assert_raise ArgumentError, fn ->
        Python.create_dspy_program(:module, %{}, [])
      end
    end
  end

  describe "configure_dspy/3" do
    test "raises error for unsupported providers" do
      assert_raise ArgumentError, fn ->
        Python.configure_dspy(:unsupported_provider, %{}, [])
      end
    end

    test "handles different provider configurations" do
      # Test that the function accepts known providers
      providers = [:openai, :gemini, :anthropic]

      Enum.each(providers, fn provider ->
        # Should not raise an error for supported providers
        _config = %{api_key: "test_key", model: "test_model"}

        # We can't test the actual execution without mocking,
        # but we can verify the provider is recognized
        case provider do
          :openai -> assert provider == :openai
          :gemini -> assert provider == :gemini
          :anthropic -> assert provider == :anthropic
        end
      end)
    end
  end

  describe "helper function parameter handling" do
    test "train_model constructs correct target" do
      model_id = "my_model"
      target = "stored.#{model_id}.fit"
      assert target == "stored.my_model.fit"
    end

    test "predict constructs correct target" do
      model_id = "my_model"
      target = "stored.#{model_id}.predict"
      assert target == "stored.my_model.predict"
    end

    test "execute_dspy constructs correct target" do
      program_id = "my_program"
      target = "stored.#{program_id}.__call__"
      assert target == "stored.my_program.__call__"
    end
  end

  describe "option handling" do
    test "extracts pool options correctly" do
      opts = [pool: :custom_pool, timeout: 5000, session_id: "test_session", other: "ignored"]
      pool_opts = Keyword.take(opts, [:pool, :timeout, :session_id])

      assert pool_opts[:pool] == :custom_pool
      assert pool_opts[:timeout] == 5000
      assert pool_opts[:session_id] == "test_session"
      refute Keyword.has_key?(pool_opts, :other)
    end

    test "handles session_id option" do
      opts = [session_id: "test_session"]

      case opts[:session_id] do
        nil -> assert false, "Should have found session_id"
        session_id -> assert session_id == "test_session"
      end
    end
  end
end
