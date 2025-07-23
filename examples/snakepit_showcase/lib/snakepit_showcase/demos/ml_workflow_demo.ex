defmodule SnakepitShowcase.Demos.MLWorkflowDemo do
  @moduledoc """
  Demonstrates advanced ML workflows including DSPy integration,
  multi-step pipelines, and model training/inference.
  """

  def run do
    IO.puts("🤖 ML Workflows Demo\n")
    
    session_id = "ml_workflow_#{System.unique_integer()}"
    
    # Demo 1: Data preprocessing
    demo_data_preprocessing(session_id)
    
    # Demo 2: Feature engineering
    demo_feature_engineering(session_id)
    
    # Demo 3: Model training
    demo_model_training(session_id)
    
    # Demo 4: Inference pipeline
    demo_inference_pipeline(session_id)
    
    # Cleanup
    Snakepit.execute_in_session(session_id, "cleanup", %{})
    
    :ok
  end

  defp demo_data_preprocessing(session_id) do
    IO.puts("1️⃣ Data Preprocessing")
    
    # Load sample data
    {:ok, result} = Snakepit.execute_in_session(session_id, "load_sample_data", %{
      dataset: "iris",
      split: 0.8
    })
    
    IO.puts("   Loaded dataset: #{result["dataset_name"]}")
    IO.puts("   Total samples: #{result["total_samples"]}")
    IO.puts("   Training samples: #{result["train_samples"]}")
    IO.puts("   Test samples: #{result["test_samples"]}")
    IO.puts("   Features: #{inspect(result["feature_names"])}")
    
    # Preprocess data
    {:ok, result} = Snakepit.execute_in_session(session_id, "preprocess_data", %{
      normalize: true,
      handle_missing: "mean",
      encode_categorical: true
    })
    
    IO.puts("\n   Preprocessing completed:")
    IO.puts("   Normalized: #{result["normalized"]}")
    IO.puts("   Missing values handled: #{result["missing_handled"]}")
    IO.puts("   Categorical encoded: #{result["categorical_encoded"]}")
  end

  defp demo_feature_engineering(session_id) do
    IO.puts("\n2️⃣ Feature Engineering")
    
    # Generate polynomial features
    {:ok, result} = Snakepit.execute_in_session(session_id, "generate_features", %{
      method: "polynomial",
      degree: 2,
      interaction_only: false
    })
    
    IO.puts("   Generated polynomial features:")
    IO.puts("   Original features: #{result["original_features"]}")
    IO.puts("   New features: #{result["new_features"]}")
    IO.puts("   Total features: #{result["total_features"]}")
    
    # Feature selection
    {:ok, result} = Snakepit.execute_in_session(session_id, "select_features", %{
      method: "mutual_info",
      k_best: 10
    })
    
    IO.puts("\n   Selected top features:")
    Enum.with_index(result["selected_features"], 1)
    |> Enum.each(fn {{name, score}, idx} ->
      IO.puts("   #{idx}. #{name}: #{Float.round(score, 3)}")
    end)
  end

  defp demo_model_training(session_id) do
    IO.puts("\n3️⃣ Model Training")
    
    # Train model with streaming progress
    IO.puts("   Training Random Forest classifier...")
    
    {:ok, stream} = Snakepit.execute_in_session_stream(
      session_id, 
      "train_model",
      %{
        algorithm: "random_forest",
        n_estimators: 100,
        max_depth: 10,
        random_state: 42
      }
    )
    
    stream
    |> Enum.each(fn chunk ->
      case chunk["type"] do
        "progress" ->
          IO.puts("   Epoch #{chunk["epoch"]}/#{chunk["total_epochs"]}: " <>
                 "accuracy=#{Float.round(chunk["accuracy"], 3)}")
        "completed" ->
          IO.puts("\n   Training completed!")
          IO.puts("   Final accuracy: #{Float.round(chunk["final_accuracy"], 3)}")
          IO.puts("   Training time: #{chunk["training_time_ms"]}ms")
      end
    end)
    
    # Cross-validation
    {:ok, result} = Snakepit.execute_in_session(session_id, "cross_validate", %{
      cv_folds: 5
    })
    
    IO.puts("\n   Cross-validation results:")
    IO.puts("   Mean accuracy: #{Float.round(result["mean_accuracy"], 3)} " <>
           "(±#{Float.round(result["std_accuracy"], 3)})")
  end

  defp demo_inference_pipeline(session_id) do
    IO.puts("\n4️⃣ Inference Pipeline")
    
    # Single prediction
    sample_data = %{
      "sepal_length" => 5.1,
      "sepal_width" => 3.5,
      "petal_length" => 1.4,
      "petal_width" => 0.2
    }
    
    {:ok, result} = Snakepit.execute_in_session(session_id, "predict_single", %{
      features: sample_data
    })
    
    IO.puts("   Single prediction:")
    IO.puts("   Input: #{inspect(sample_data)}")
    IO.puts("   Prediction: #{result["prediction"]}")
    IO.puts("   Confidence: #{Float.round(result["confidence"], 3)}")
    
    # Batch prediction with embeddings
    IO.puts("\n   Batch prediction with embeddings...")
    
    {:ok, result} = Snakepit.execute_in_session(session_id, "predict_batch_with_embeddings", %{
      batch_size: 32,
      include_embeddings: true,
      embedding_dim: 128
    })
    
    IO.puts("   Processed #{result["batch_size"]} samples")
    IO.puts("   Predictions shape: #{inspect(result["predictions_shape"])}")
    IO.puts("   Embeddings shape: #{inspect(result["embeddings_shape"])}")
    IO.puts("   Average confidence: #{Float.round(result["avg_confidence"], 3)}")
    
    # The embeddings are large and use binary serialization
    if result["embeddings_encoding"] == "binary" do
      IO.puts("   ✅ Embeddings transferred using binary encoding!")
    end
  end
end