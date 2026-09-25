defmodule SnakepitShowcase.Demos.MLWorkflowDemo do
  @moduledoc """
  Demonstrates ML workflow with proper error handling.

  This demo shows best practices for:
  - Graceful error recovery
  - Timeout handling for long operations
  - Fallback strategies
  - Informative error messages
  """

  def run do
    IO.puts("\n🤖 Machine Learning Workflow Demo\n")

    with {:ok, session_id} <- create_session(),
         :ok <- load_and_preprocess_data(session_id),
         :ok <- train_model_with_progress(session_id),
         :ok <- evaluate_model(session_id) do
      IO.puts("\n✅ ML workflow completed successfully")
      cleanup_session(session_id)
    else
      {:error, reason} ->
        IO.puts("\n❌ ML workflow failed: #{inspect(reason)}")
        handle_ml_error(reason)
    end
  end

  defp create_session do
    session_id = "ml_workflow_#{System.unique_integer()}"

    case Snakepit.execute_in_session(session_id, "init_session", %{}) do
      {:ok, _} -> {:ok, session_id}
      {:error, reason} -> {:error, {:session_creation_failed, reason}}
    end
  end

  defp cleanup_session(session_id) do
    case Snakepit.execute_in_session(session_id, "cleanup", %{}) do
      {:ok, result} ->
        IO.puts("\nSession cleanup:")
        IO.puts("  Duration: #{result["duration_ms"]}ms")
        IO.puts("  Commands executed: #{result["command_count"]}")

      {:error, _} ->
        # Cleanup errors are non-fatal
        IO.puts("\n⚠️  Session cleanup failed (non-fatal)")
    end
  end

  defp load_and_preprocess_data(session_id) do
    IO.puts("1️⃣ Loading and Preprocessing Data")

    with :ok <- load_data(session_id),
         :ok <- preprocess_data(session_id) do
      :ok
    end
  end

  defp load_data(session_id) do
    case Snakepit.execute_in_session(session_id, "load_sample_data", %{
           dataset: "iris",
           split: 0.8
         }) do
      {:ok, result} ->
        IO.puts("   Loaded #{result["total_samples"]} samples")
        IO.puts("   Features: #{inspect(result["feature_names"])}")
        :ok

      {:error, %{error_type: "DataNotFoundError"}} ->
        IO.puts("   ⚠️  Dataset not found, using synthetic data")
        generate_synthetic_data(session_id)

      {:error, reason} ->
        {:error, {:data_loading_failed, reason}}
    end
  end

  defp generate_synthetic_data(session_id) do
    # Fallback to synthetic data generation
    case Snakepit.execute_in_session(session_id, "load_sample_data", %{
           dataset: "synthetic",
           split: 0.8
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:synthetic_data_failed, reason}}
    end
  end

  defp preprocess_data(session_id) do
    case Snakepit.execute_in_session(session_id, "preprocess_data", %{
           normalize: true,
           handle_missing: "mean",
           encode_categorical: true
         }) do
      {:ok, result} ->
        IO.puts("   Preprocessing completed: normalized=#{result["normalized"]}")
        :ok

      {:error, reason} ->
        {:error, {:preprocessing_failed, reason}}
    end
  end

  defp train_model_with_progress(session_id) do
    IO.puts("\n2️⃣ Training Model")

    # Set up timeout for long-running training
    # 5 minutes
    timeout = 300_000
    callback_fn = &handle_training_chunk/1

    # Use streaming with error handling
    case Snakepit.execute_in_session_stream(
           session_id,
           "train_model",
           %{algorithm: "random_forest", max_depth: 10},
           callback_fn,
           timeout: timeout
         ) do
      {:error, reason} ->
        IO.puts("   ⚠️  Streaming training unavailable: #{inspect(reason)}")
        :ok

      :ok ->
        :ok
    end
  end

  defp handle_training_chunk(%{"type" => "progress"} = update) do
    IO.puts(
      "   Epoch #{update["epoch"]}/#{update["total_epochs"]}: " <>
        "accuracy = #{Float.round(update["accuracy"], 3)}"
    )

    :ok
  end

  defp handle_training_chunk(%{"type" => "completed"} = result) do
    IO.puts("   ✅ Training completed: accuracy = #{Float.round(result["final_accuracy"], 3)}")
    :halt
  end

  defp handle_training_chunk(%{"error" => error}) do
    IO.puts("   ❌ Training stream error: #{inspect(error)}")
    {:halt, {:training_failed, error}}
  end

  defp handle_training_chunk(_chunk), do: :ok

  defp evaluate_model(session_id) do
    IO.puts("\n3️⃣ Model Evaluation")

    with :ok <- cross_validate(session_id),
         :ok <- test_predictions(session_id) do
      :ok
    end
  end

  defp cross_validate(session_id) do
    case Snakepit.execute_in_session(session_id, "cross_validate", %{cv_folds: 5}) do
      {:ok, result} ->
        mean_acc = Float.round(result["mean_accuracy"], 3)
        std_acc = Float.round(result["std_accuracy"], 3)
        IO.puts("   Cross-validation: #{mean_acc} (±#{std_acc})")

        if mean_acc < 0.7 do
          IO.puts("   ⚠️  Warning: Low accuracy detected")
        end

        :ok

      {:error, reason} ->
        # Cross-validation failure is non-fatal
        IO.puts("   ⚠️  Cross-validation failed: #{inspect(reason)}")
        :ok
    end
  end

  defp test_predictions(session_id) do
    # Test single prediction
    sample = %{
      "sepal_length" => 5.1,
      "sepal_width" => 3.5,
      "petal_length" => 1.4,
      "petal_width" => 0.2
    }

    case Snakepit.execute_in_session(session_id, "predict_single", %{features: sample}) do
      {:ok, result} ->
        IO.puts(
          "   Test prediction: #{result["prediction"]} " <>
            "(confidence: #{Float.round(result["confidence"], 2)})"
        )

        :ok

      {:error, %{error_type: "ModelNotTrainedError"}} ->
        IO.puts("   ⚠️  Model not trained, skipping predictions")
        :ok

      {:error, reason} ->
        {:error, {:prediction_failed, reason}}
    end
  end

  defp handle_ml_error({:data_loading_failed, _reason}) do
    IO.puts("""

    💡 Tip: Ensure your Python environment has the required packages:
       - numpy
       - sklearn (if using real datasets)
    """)
  end

  defp handle_ml_error(_) do
    IO.puts("\n💡 Tip: Check the logs for more details")
  end
end
