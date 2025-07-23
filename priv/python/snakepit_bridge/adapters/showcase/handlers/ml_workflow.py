"""Machine learning workflow handler for showcase adapter."""

import numpy as np
import time
from typing import Dict, Any
from ..tool import Tool, StreamChunk


class MLWorkflowHandler:
    """Handler for machine learning workflow operations."""
    
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
        """Load sample dataset and store in SessionContext."""
        # Simulate loading iris dataset
        if dataset == "iris":
            # Generate fake iris-like data
            total_samples = 150
            train_samples = int(total_samples * split)
            test_samples = total_samples - train_samples
            
            # Generate data
            train_data = {
                "X_train": np.random.randn(train_samples, 4).tolist(),  # Convert to list for JSON
                "y_train": np.random.randint(0, 3, train_samples).tolist(),
                "X_test": np.random.randn(test_samples, 4).tolist(),
                "y_test": np.random.randint(0, 3, test_samples).tolist(),
                "feature_names": ["sepal_length", "sepal_width", "petal_length", "petal_width"]
            }
            
            # Store in SessionContext as tensor variables
            ctx.register_variable("ml_train_data", "tensor", {
                "shape": [train_samples, 4],
                "data": train_data["X_train"]
            })
            ctx.register_variable("ml_train_labels", "integer", train_data["y_train"])
            ctx.register_variable("ml_test_data", "tensor", {
                "shape": [test_samples, 4], 
                "data": train_data["X_test"]
            })
            ctx.register_variable("ml_test_labels", "integer", train_data["y_test"])
            ctx['ml_feature_names'] = train_data["feature_names"]
            
            return {
                "dataset_name": dataset,
                "total_samples": total_samples,
                "train_samples": train_samples,
                "test_samples": test_samples,
                "feature_names": train_data["feature_names"]
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
        # Check if ML data exists in session
        if 'ml_train_data' in ctx:
            train_data = ctx.get_variable('ml_train_data')
            original = len(train_data['data'][0]) if train_data['data'] else 4
            
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
        # Get feature names from session
        if 'ml_feature_names' in ctx:
            feature_names = ctx['ml_feature_names']
            # Generate fake feature scores
            scores = np.random.rand(len(feature_names))
            selected = sorted(zip(feature_names, scores), 
                            key=lambda x: x[1], reverse=True)[:k_best]
            
            return {"selected_features": selected}
        else:
            raise ValueError("No ML data loaded. Please run load_sample_data first.")
    
    def train_model(self, ctx, algorithm: str,
                   **kwargs) -> StreamChunk:
        """Train model with streaming progress."""
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
        
        # Store model in SessionContext
        ctx['ml_model'] = {
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
        accuracies = [0.92 + np.random.rand() * 0.06 for _ in range(cv_folds)]
        mean_acc = np.mean(accuracies)
        std_acc = np.std(accuracies)
        
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
            # Generate embeddings (this will use binary encoding if large)
            embeddings = np.random.randn(batch_size, embedding_dim)
            
            # Store as variable to demonstrate binary encoding
            ctx.register_variable("batch_embeddings", "tensor", {
                "shape": [batch_size, embedding_dim],
                "data": embeddings.tolist()
            })
            
            total_bytes = batch_size * embedding_dim * 8
            result.update({
                "embeddings_shape": [batch_size, embedding_dim],
                "embeddings_encoding": "binary" if total_bytes > 10240 else "json"
            })
        
        return result