"""Machine learning workflow handler for showcase adapter."""

import numpy as np
import time
from typing import Dict, Any
from ..tool import Tool, StreamChunk


class MLWorkflowHandler:
    """Handler for machine learning workflow operations.
    
    Note: In a production system, ML data would be stored via SessionContext
    variables. For this showcase, we use a simple in-memory approach.
    """
    
    # Temporary storage for ML data and models
    _ml_data = {}
    _ml_models = {}
    
    def get_tools(self) -> Dict[str, Tool]:
        """Return all tools provided by this handler."""
        return {
            "load_sample_data": Tool(self.load_sample_data),
            "preprocess_data": Tool(self.preprocess_data),
            "generate_features": Tool(self.generate_features),
            "select_features": Tool(self.select_features),
            "train_model": Tool(self.train_model),
            "cross_validate": Tool(self.cross_validate),
            "predict_single": Tool(self.predict_single),
            "predict_batch_with_embeddings": Tool(self.predict_batch_with_embeddings),
        }
    
    def load_sample_data(self, ctx, dataset: str, 
                        split: float) -> Dict[str, Any]:
        """Load sample dataset."""
        session_id = ctx.session_id
        
        # Simulate loading iris dataset
        if dataset == "iris":
            # Generate fake iris-like data
            total_samples = 150
            train_samples = int(total_samples * split)
            test_samples = total_samples - train_samples
            
            # Generate and store data
            self._ml_data[session_id] = {
                "X_train": np.random.randn(train_samples, 4),
                "y_train": np.random.randint(0, 3, train_samples),
                "X_test": np.random.randn(test_samples, 4),
                "y_test": np.random.randint(0, 3, test_samples),
                "feature_names": ["sepal_length", "sepal_width", "petal_length", "petal_width"]
            }
            
            return {
                "dataset_name": dataset,
                "total_samples": total_samples,
                "train_samples": train_samples,
                "test_samples": test_samples,
                "feature_names": self._ml_data[session_id]["feature_names"]
            }
        else:
            # Synthetic data fallback
            total_samples = 100
            train_samples = int(total_samples * split)
            test_samples = total_samples - train_samples
            
            self._ml_data[session_id] = {
                "X_train": np.random.randn(train_samples, 5),
                "y_train": np.random.randint(0, 2, train_samples),
                "X_test": np.random.randn(test_samples, 5),
                "y_test": np.random.randint(0, 2, test_samples),
                "feature_names": [f"feature_{i}" for i in range(5)]
            }
            
            return {
                "dataset_name": "synthetic",
                "total_samples": total_samples,
                "train_samples": train_samples,
                "test_samples": test_samples,
                "feature_names": self._ml_data[session_id]["feature_names"]
            }
    
    def preprocess_data(self, ctx, normalize: bool,
                       handle_missing: str, encode_categorical: bool) -> Dict[str, Any]:
        """Preprocess the loaded data."""
        # Simulate preprocessing
        time.sleep(0.5)
        
        return {
            "normalized": normalize,
            "missing_handled": True,
            "categorical_encoded": encode_categorical
        }
    
    def generate_features(self, ctx, method: str,
                         degree: int, interaction_only: bool) -> Dict[str, Any]:
        """Generate polynomial features."""
        session_id = ctx.session_id
        
        # Check if ML data exists
        if session_id in self._ml_data:
            original = self._ml_data[session_id]["X_train"].shape[1]
            
            # Simulate polynomial feature expansion
            if method == "polynomial":
                new_features = (degree + 1) ** original - original
            else:
                new_features = original * 2
            
            return {
                "original_features": original,
                "new_features": new_features,
                "total_features": original + new_features
            }
        else:
            raise ValueError("No ML data loaded. Please run load_sample_data first.")
    
    def select_features(self, ctx, method: str,
                       k_best: int) -> Dict[str, Any]:
        """Select best features."""
        session_id = ctx.session_id
        
        if session_id in self._ml_data:
            feature_names = self._ml_data[session_id]["feature_names"]
            # Generate fake feature scores
            scores = np.random.rand(len(feature_names)).tolist()
            selected = sorted(zip(feature_names, scores), 
                            key=lambda x: x[1], reverse=True)[:k_best]
            
            return {"selected_features": selected}
        else:
            raise ValueError("No ML data loaded. Please run load_sample_data first.")
    
    def train_model(self, ctx, algorithm: str,
                   **kwargs) -> StreamChunk:
        """Train model with streaming progress."""
        session_id = ctx.session_id
        epochs = 10
        
        for epoch in range(epochs):
            # Simulate training
            time.sleep(0.2)
            accuracy = 0.6 + (0.4 * epoch / epochs) + np.random.rand() * 0.05
            
            yield StreamChunk({
                "type": "progress",
                "epoch": epoch + 1,
                "total_epochs": epochs,
                "accuracy": accuracy
            }, is_final=False)
        
        # Final result
        training_time = epochs * 200
        final_accuracy = 0.95 + np.random.rand() * 0.04
        
        # Store model
        self._ml_models[session_id] = {
            "algorithm": algorithm,
            "accuracy": final_accuracy,
            "trained_at": time.time()
        }
        
        yield StreamChunk({
            "type": "completed",
            "final_accuracy": final_accuracy,
            "training_time_ms": training_time
        }, is_final=True)
    
    def cross_validate(self, ctx, cv_folds: int) -> Dict[str, Any]:
        """Perform cross-validation."""
        # Simulate CV results
        accuracies = [float(0.92 + np.random.rand() * 0.06) for _ in range(cv_folds)]
        mean_acc = float(np.mean(accuracies))
        std_acc = float(np.std(accuracies))
        
        return {
            "mean_accuracy": mean_acc,
            "std_accuracy": std_acc,
            "fold_accuracies": accuracies
        }
    
    def predict_single(self, ctx, features: Dict[str, float]) -> Dict[str, Any]:
        """Make a single prediction."""
        # Simulate prediction
        prediction = np.random.choice(["setosa", "versicolor", "virginica"])
        confidence = 0.8 + np.random.rand() * 0.2
        
        return {
            "prediction": prediction,
            "confidence": confidence
        }
    
    def predict_batch_with_embeddings(self, ctx, batch_size: int,
                                     include_embeddings: bool, 
                                     embedding_dim: int) -> Dict[str, Any]:
        """Batch prediction with embeddings."""
        # Generate predictions
        predictions = np.random.randint(0, 3, batch_size)
        confidences = 0.7 + np.random.rand(batch_size) * 0.3
        
        result = {
            "batch_size": batch_size,
            "predictions_shape": list(predictions.shape),
            "avg_confidence": float(np.mean(confidences))
        }
        
        if include_embeddings:
            # Generate embeddings
            embeddings = np.random.randn(batch_size, embedding_dim)
            
            # For demo purposes, we'll just report the encoding type
            # In production, this would use ctx.register_variable()
            total_bytes = batch_size * embedding_dim * 8
            result.update({
                "embeddings_shape": [batch_size, embedding_dim],
                "embeddings_encoding": "binary" if total_bytes > 10240 else "json",
                "embeddings_size_bytes": total_bytes
            })
        
        return result
