#!/usr/bin/env elixir

# Enhanced Python Bridge - Data Science Workflow Example
# 
# This script demonstrates a complete data science workflow using the enhanced
# Python bridge with pandas, scikit-learn, and other data science libraries.

# Configure Snakepit to use the enhanced Python adapter
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.EnhancedPython)
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{pool_size: 2})

# Stop the application if it's running
Application.stop(:snakepit)

# Start the application with new configuration
{:ok, _} = Application.ensure_all_started(:snakepit)

IO.puts("=== Data Science Workflow with Enhanced Python Bridge ===\n")

# Create a session for this workflow
session_id = Snakepit.Python.create_session()
IO.puts("Created session: #{session_id}\n")

# Step 1: Create sample data using pandas
IO.puts("1. Creating Sample Dataset:")

# Create a simple dataset
sample_data = %{
  "data" => [
    [1, 2, 0],
    [2, 3, 0], 
    [3, 4, 0],
    [4, 5, 1],
    [5, 6, 1],
    [6, 7, 1]
  ],
  "columns" => ["feature1", "feature2", "target"]
}

case Snakepit.Python.call("pandas.DataFrame", sample_data, [store_as: "df", session_id: session_id]) do
  {:ok, result} ->
    IO.puts("   ✓ Created DataFrame:")
    if result["result"]["shape"] do
      shape = result["result"]["shape"]
      IO.puts("     Shape: #{inspect(shape)}")
      IO.puts("     Columns: #{inspect(result["result"]["columns"])}")
    end
  {:error, error} ->
    IO.puts("   ✗ Error creating DataFrame: #{error}")
end

IO.puts("")

# Step 2: Explore the data
IO.puts("2. Data Exploration:")

# Get basic info about the DataFrame
case Snakepit.Python.call("stored.df.describe", %{}, session_id: session_id) do
  {:ok, _result} ->
    IO.puts("   ✓ Data description available")
  {:error, error} ->
    IO.puts("   ✗ Error describing data: #{error}")
end

# Get data types
case Snakepit.Python.call("stored.df.dtypes", %{}, session_id: session_id) do
  {:ok, _result} ->
    IO.puts("   ✓ Data types retrieved")
  {:error, error} ->
    IO.puts("   ✗ Error getting dtypes: #{error}")
end

IO.puts("")

# Step 3: Prepare features and target
IO.puts("3. Feature Preparation:")

# Extract features (all columns except 'target')
case Snakepit.Python.call("stored.df.drop", %{columns: ["target"], axis: 1}, [store_as: "X", session_id: session_id]) do
  {:ok, _result} ->
    IO.puts("   ✓ Features extracted (X)")
  {:error, error} ->
    IO.puts("   ✗ Error extracting features: #{error}")
end

# Extract target variable
case Snakepit.Python.call("stored.df.__getitem__", %{key: "target"}, [store_as: "y", session_id: session_id]) do
  {:ok, _result} ->
    IO.puts("   ✓ Target extracted (y)")
  {:error, error} ->
    IO.puts("   ✗ Error extracting target: #{error}")
end

IO.puts("")

# Step 4: Create and train a model
IO.puts("4. Model Training:")

# Create a Random Forest Classifier
case Snakepit.Python.create_model(:random_forest, %{n_estimators: 10, random_state: 42}, [store_as: "model", session_id: session_id]) do
  {:ok, _result} ->
    IO.puts("   ✓ Random Forest model created")
  {:error, error} ->
    IO.puts("   ✗ Error creating model: #{error}")
end

# Train the model
case Snakepit.Python.train_model("model", %{X: "stored.X", y: "stored.y"}, session_id: session_id) do
  {:ok, _result} ->
    IO.puts("   ✓ Model trained successfully")
  {:error, error} ->
    IO.puts("   ✗ Error training model: #{error}")
end

IO.puts("")

# Step 5: Make predictions
IO.puts("5. Making Predictions:")

# Predict on the same data (for demonstration)
case Snakepit.Python.predict("model", %{X: "stored.X"}, [store_as: "predictions", session_id: session_id]) do
  {:ok, result} ->
    IO.puts("   ✓ Predictions made")
    predictions = result["result"]
    IO.puts("   Prediction result type: #{predictions["type"]}")
  {:error, error} ->
    IO.puts("   ✗ Error making predictions: #{error}")
end

IO.puts("")

# Step 6: Model evaluation
IO.puts("6. Model Evaluation:")

# Calculate accuracy using sklearn metrics
case Snakepit.Python.call("sklearn.metrics.accuracy_score", %{
  y_true: "stored.y",
  y_pred: "stored.predictions"
}, session_id: session_id) do
  {:ok, result} ->
    accuracy = result["result"]["value"]
    IO.puts("   ✓ Accuracy: #{accuracy}")
  {:error, error} ->
    IO.puts("   ✗ Error calculating accuracy: #{error}")
end

# Get feature importance
case Snakepit.Python.call("stored.model.feature_importances_", %{}, session_id: session_id) do
  {:ok, result} ->
    IO.puts("   ✓ Feature importances retrieved")
    if result["result"]["value"] do
      importances = result["result"]["value"]
      IO.puts("   Feature importances: #{inspect(importances)}")
    end
  {:error, error} ->
    IO.puts("   ✗ Error getting feature importances: #{error}")
end

IO.puts("")

# Step 7: Advanced pipeline with preprocessing
IO.puts("7. Advanced Pipeline with Preprocessing:")

# Create a preprocessing and modeling pipeline
pipeline_steps = [
  # Create a StandardScaler
  {:call, "sklearn.preprocessing.StandardScaler", %{}, store_as: "scaler"},
  
  # Fit and transform the features
  {:call, "stored.scaler.fit_transform", %{X: "stored.X"}, store_as: "X_scaled"},
  
  # Create a new model for scaled data
  {:call, "sklearn.linear_model.LogisticRegression", %{random_state: 42}, store_as: "lr_model"},
  
  # Train the logistic regression model
  {:call, "stored.lr_model.fit", %{X: "stored.X_scaled", y: "stored.y"}},
  
  # Make predictions with the new model
  {:call, "stored.lr_model.predict", %{X: "stored.X_scaled"}, store_as: "lr_predictions"}
]

case Snakepit.Python.pipeline(pipeline_steps, session_id: session_id) do
  {:ok, result} ->
    completed_steps = result["steps_completed"]
    IO.puts("   ✓ Pipeline completed: #{completed_steps} steps")
    
    # Calculate accuracy for the logistic regression model
    case Snakepit.Python.call("sklearn.metrics.accuracy_score", %{
      y_true: "stored.y",
      y_pred: "stored.lr_predictions"
    }, session_id: session_id) do
      {:ok, acc_result} ->
        lr_accuracy = acc_result["result"]["value"]
        IO.puts("   ✓ Logistic Regression Accuracy: #{lr_accuracy}")
      {:error, error} ->
        IO.puts("   ✗ Error calculating LR accuracy: #{error}")
    end
    
  {:error, error} ->
    IO.puts("   ✗ Pipeline error: #{error}")
end

IO.puts("")

# Step 8: Inspect stored objects
IO.puts("8. Session Summary:")

case Snakepit.Python.list_stored(session_id: session_id) do
  {:ok, result} ->
    stored_objects = result["stored_objects"]
    IO.puts("   Objects created in this session:")
    Enum.each(stored_objects, fn object_id ->
      IO.puts("     - #{object_id}")
    end)
    IO.puts("   Total objects: #{length(stored_objects)}")
  {:error, error} ->
    IO.puts("   ✗ Error listing stored objects: #{error}")
end

IO.puts("")

# Step 9: Model inspection
IO.puts("9. Model Inspection:")

case Snakepit.Python.inspect("stored.model", session_id: session_id) do
  {:ok, result} ->
    inspection = result["inspection"]
    IO.puts("   Random Forest Model:")
    IO.puts("     Type: #{inspection["type"]}")
    IO.puts("     Module: #{inspection["module"]}")
    if inspection["attributes"] do
      IO.puts("     Available attributes: #{length(inspection["attributes"])}")
    end
  {:error, error} ->
    IO.puts("   ✗ Error inspecting model: #{error}")
end

case Snakepit.Python.inspect("stored.lr_model", session_id: session_id) do
  {:ok, result} ->
    inspection = result["inspection"]
    IO.puts("   Logistic Regression Model:")
    IO.puts("     Type: #{inspection["type"]}")
    IO.puts("     Module: #{inspection["module"]}")
  {:error, error} ->
    IO.puts("   ✗ Error inspecting LR model: #{error}")
end

IO.puts("")

# Step 10: Cleanup demonstration
IO.puts("10. Selective Cleanup:")

# Delete specific objects
objects_to_delete = ["df", "scaler", "X_scaled"]

Enum.each(objects_to_delete, fn object_id ->
  case Snakepit.Python.delete_stored(object_id, session_id: session_id) do
    {:ok, _} ->
      IO.puts("   ✓ Deleted: #{object_id}")
    {:error, error} ->
      IO.puts("   ✗ Error deleting #{object_id}: #{error}")
  end
end)

# Check remaining objects
case Snakepit.Python.list_stored(session_id: session_id) do
  {:ok, result} ->
    remaining = result["stored_objects"]
    IO.puts("   Remaining objects: #{inspect(remaining)}")
  {:error, error} ->
    IO.puts("   ✗ Error listing remaining objects: #{error}")
end

IO.puts("\n=== Data Science Workflow Complete ===")
IO.puts("Session ID: #{session_id}")
IO.puts("Note: Objects in this session will automatically expire based on session TTL.")

# Optional: Demonstrate cross-session functionality
IO.puts("\n=== Cross-Session Demonstration ===")

# Create a new session
new_session = Snakepit.Python.create_session()
IO.puts("Created new session: #{new_session}")

# Try to access objects from the previous session (should fail)
case Snakepit.Python.retrieve("model", session_id: new_session) do
  {:ok, _result} ->
    IO.puts("   Unexpected: Found model in new session")
  {:error, _error} ->
    IO.puts("   ✓ Expected: Model not found in new session - sessions are isolated")
end

IO.puts("\n=== Complete ===")