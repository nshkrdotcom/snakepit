import numpy as np
import time
import os
import psutil
from typing import Dict, Any, List, Optional
from datetime import datetime

# Add parent directory to path to import snakepit_bridge
import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../../priv/python'))

from snakepit_bridge import Tool, SessionContext, StreamChunk

class ShowcaseAdapter:
    """Main adapter demonstrating all Snakepit features."""
    
    def __init__(self):
        self.session_start_times = {}
        self.command_counts = {}
        self.counters = {}
        self.tools = {
            # Basic operations
            "ping": Tool(self.ping),
            "echo": Tool(self.echo),
            "error_demo": Tool(self.error_demo),
            "adapter_info": Tool(self.adapter_info),
            
            # Binary serialization demos
            "create_tensor": Tool(self.create_tensor),
            "create_embedding": Tool(self.create_embedding),
            "benchmark_encoding": Tool(self.benchmark_encoding),
            
            # Session operations
            "init_session": Tool(self.init_session),
            "cleanup": Tool(self.cleanup_session),
            "set_counter": Tool(self.set_counter),
            "get_counter": Tool(self.get_counter),
            "increment_counter": Tool(self.increment_counter),
            "get_worker_info": Tool(self.get_worker_info),
            
            # Streaming operations
            "stream_progress": Tool(self.stream_progress),
            "stream_fibonacci": Tool(self.stream_fibonacci),
            "generate_dataset": Tool(self.generate_dataset),
            "infinite_stream": Tool(self.infinite_stream),
            
            # Concurrent operations
            "cpu_bound_task": Tool(self.cpu_bound_task),
            "sleep_task": Tool(self.sleep_task),
            "lightweight_task": Tool(self.lightweight_task),
            "get_pool_stats": Tool(self.get_pool_stats),
            
            # Variable operations
            "register_variable": Tool(self.register_variable),
            "get_variable": Tool(self.get_variable),
            "set_variable": Tool(self.set_variable),
            "set_variable_with_history": Tool(self.set_variable_with_history),
            "get_variables": Tool(self.get_variables),
            "set_variables": Tool(self.set_variables),
            
            # ML operations
            "load_sample_data": Tool(self.load_sample_data),
            "preprocess_data": Tool(self.preprocess_data),
            "generate_features": Tool(self.generate_features),
            "select_features": Tool(self.select_features),
            "train_model": Tool(self.train_model),
            "cross_validate": Tool(self.cross_validate),
            "predict_single": Tool(self.predict_single),
            "predict_batch_with_embeddings": Tool(self.predict_batch_with_embeddings),
        }
        
        # ML state
        self.ml_data = {}
        self.ml_models = {}
    
    # Basic operations
    def ping(self, ctx: SessionContext, message: str = "pong") -> Dict[str, str]:
        return {"message": message, "timestamp": str(time.time())}
    
    def echo(self, ctx: SessionContext, **kwargs) -> Dict[str, Any]:
        return {"echoed": kwargs}
    
    def error_demo(self, ctx: SessionContext, error_type: str = "generic") -> None:
        if error_type == "value":
            raise ValueError("This is a demonstration ValueError")
        elif error_type == "runtime":
            raise RuntimeError("This is a demonstration RuntimeError")
        else:
            raise Exception("This is a generic exception")
    
    def adapter_info(self, ctx: SessionContext) -> Dict[str, Any]:
        return {
            "adapter_name": "ShowcaseAdapter",
            "version": "1.0.0",
            "capabilities": ["binary_serialization", "streaming", "ml_workflows", "variables"]
        }
    
    # Binary serialization methods
    def create_tensor(self, ctx: SessionContext, name: str, shape: List[int], 
                     size_bytes: int = None) -> Dict[str, Any]:
        """Create a tensor and demonstrate encoding detection."""
        # Generate random data
        total_elements = np.prod(shape)
        data = np.random.randn(*shape)
        
        # Calculate actual size
        actual_bytes = total_elements * 8  # float64
        
        # Register as tensor variable
        ctx.register_variable(name, "tensor", {
            "shape": shape,
            "data": data.tolist()
        })
        
        # Check which encoding was used (based on size)
        encoding = "binary" if actual_bytes > 10240 else "json"
        
        return {
            "name": name,
            "shape": shape,
            "size_bytes": actual_bytes,
            "encoding": encoding,
            "elements": total_elements
        }
    
    def create_embedding(self, ctx: SessionContext, name: str, 
                        dimensions: int, batch_size: int = 1) -> Dict[str, Any]:
        """Create embeddings and measure performance."""
        start_time = time.time()
        
        # Generate batch of embeddings
        embeddings = np.random.randn(batch_size, dimensions)
        
        # Flatten for storage as embedding type
        flat_embeddings = embeddings.flatten().tolist()
        
        # Register the embedding
        ctx.register_variable(name, "embedding", flat_embeddings)
        
        elapsed_ms = (time.time() - start_time) * 1000
        total_bytes = batch_size * dimensions * 8
        encoding = "binary" if total_bytes > 10240 else "json"
        
        return {
            "name": name,
            "dimensions": dimensions,
            "batch_size": batch_size,
            "total_bytes": total_bytes,
            "encoding": encoding,
            "time_ms": round(elapsed_ms, 2)
        }
    
    def benchmark_encoding(self, ctx: SessionContext, shape: List[int], 
                          force_binary: bool = False) -> Dict[str, Any]:
        """Benchmark encoding performance."""
        # Create data
        data = np.random.randn(*shape)
        
        # Force encoding type by manipulating size
        if force_binary and np.prod(shape) * 8 < 10240:
            # Pad data to force binary
            padding_needed = int(10240 / 8) - np.prod(shape)
            padded_data = np.concatenate([data.flatten(), np.zeros(padding_needed)])
            tensor_data = {"shape": shape + [padding_needed], "data": padded_data.tolist()}
        else:
            tensor_data = {"shape": shape, "data": data.tolist()}
        
        # Register and measure
        var_name = f"benchmark_{int(time.time() * 1000)}"
        ctx.register_variable(var_name, "tensor", tensor_data)
        
        return {"success": True}
    
    # Session operations
    def init_session(self, ctx: SessionContext, **kwargs) -> Dict[str, Any]:
        session_id = ctx.session_id
        self.session_start_times[session_id] = time.time()
        self.command_counts[session_id] = 0
        self.counters[session_id] = 0
        
        return {
            "timestamp": datetime.now().isoformat(),
            "worker_pid": os.getpid(),
            "session_id": session_id
        }
    
    def cleanup_session(self, ctx: SessionContext) -> Dict[str, Any]:
        session_id = ctx.session_id
        start_time = self.session_start_times.get(session_id, time.time())
        duration_ms = (time.time() - start_time) * 1000
        command_count = self.command_counts.get(session_id, 0)
        
        # Cleanup
        self.session_start_times.pop(session_id, None)
        self.command_counts.pop(session_id, None)
        self.counters.pop(session_id, None)
        
        return {
            "duration_ms": round(duration_ms, 2),
            "command_count": command_count
        }
    
    def set_counter(self, ctx: SessionContext, value: int) -> Dict[str, Any]:
        self.counters[ctx.session_id] = value
        self.command_counts[ctx.session_id] = self.command_counts.get(ctx.session_id, 0) + 1
        return {"value": value}
    
    def get_counter(self, ctx: SessionContext) -> Dict[str, Any]:
        self.command_counts[ctx.session_id] = self.command_counts.get(ctx.session_id, 0) + 1
        return {"value": self.counters.get(ctx.session_id, 0)}
    
    def increment_counter(self, ctx: SessionContext) -> Dict[str, Any]:
        self.counters[ctx.session_id] = self.counters.get(ctx.session_id, 0) + 1
        self.command_counts[ctx.session_id] = self.command_counts.get(ctx.session_id, 0) + 1
        return {"value": self.counters[ctx.session_id]}
    
    def get_worker_info(self, ctx: SessionContext, call_number: int) -> Dict[str, Any]:
        self.command_counts[ctx.session_id] = self.command_counts.get(ctx.session_id, 0) + 1
        return {
            "worker_pid": str(os.getpid()),
            "call_number": call_number,
            "session_id": ctx.session_id
        }
    
    # Streaming operations
    def stream_progress(self, ctx: SessionContext, steps: int = 10) -> StreamChunk:
        """Demonstrate streaming with progress updates."""
        for i in range(steps):
            progress = (i + 1) / steps * 100
            yield StreamChunk({
                "step": i + 1,
                "total": steps,
                "progress": round(progress, 1),
                "message": f"Processing step {i + 1}/{steps}"
            }, is_final=(i == steps - 1))
            time.sleep(0.1)
    
    def stream_fibonacci(self, ctx: SessionContext, count: int = 20) -> StreamChunk:
        """Stream Fibonacci sequence."""
        a, b = 0, 1
        for i in range(count):
            yield StreamChunk({
                "index": i + 1,
                "value": a
            }, is_final=(i == count - 1))
            a, b = b, a + b
            time.sleep(0.05)
    
    def generate_dataset(self, ctx: SessionContext, rows: int = 1000, 
                        chunk_size: int = 100) -> StreamChunk:
        """Generate and stream a large dataset."""
        total_sent = 0
        while total_sent < rows:
            rows_in_chunk = min(chunk_size, rows - total_sent)
            total_sent += rows_in_chunk
            
            # Generate some dummy data
            data = np.random.randn(rows_in_chunk, 10)
            
            yield StreamChunk({
                "rows_in_chunk": rows_in_chunk,
                "total_rows": total_sent,
                "data_sample": data[0].tolist()  # Just first row as sample
            }, is_final=(total_sent >= rows))
            
            time.sleep(0.1)
    
    def infinite_stream(self, ctx: SessionContext, delay_ms: int = 500) -> StreamChunk:
        """Infinite stream for testing cancellation."""
        counter = 0
        while True:
            counter += 1
            yield StreamChunk({
                "message": f"Message #{counter}",
                "timestamp": datetime.now().isoformat()
            }, is_final=False)
            time.sleep(delay_ms / 1000.0)
    
    # Concurrent operations
    def cpu_bound_task(self, ctx: SessionContext, task_id: str, 
                      duration_ms: int) -> Dict[str, Any]:
        """Simulate CPU-bound work."""
        start_time = time.time()
        
        # Simulate work
        result = 0
        iterations = duration_ms * 1000  # Adjust for CPU speed
        for i in range(iterations):
            result += i ** 2
        
        actual_duration = (time.time() - start_time) * 1000
        
        return {
            "task_id": task_id,
            "result": result % 1000000,  # Keep manageable
            "actual_duration_ms": round(actual_duration, 2)
        }
    
    def sleep_task(self, ctx: SessionContext, duration_ms: int, 
                   task_number: int) -> Dict[str, Any]:
        """Simple sleep task."""
        time.sleep(duration_ms / 1000.0)
        return {
            "task_number": task_number,
            "slept_ms": duration_ms
        }
    
    def lightweight_task(self, ctx: SessionContext, iteration: int) -> Dict[str, Any]:
        """Very lightweight task for benchmarking."""
        return {
            "iteration": iteration,
            "result": iteration * 2
        }
    
    def get_pool_stats(self, ctx: SessionContext) -> Dict[str, Any]:
        """Get current pool statistics."""
        process = psutil.Process(os.getpid())
        memory_mb = process.memory_info().rss / 1024 / 1024
        
        return {
            "active_workers": len(self.session_start_times),
            "memory_mb": round(memory_mb, 2),
            "pid": os.getpid()
        }
    
    # Variable operations
    def register_variable(self, ctx: SessionContext, name: str, type: str, 
                         initial_value: Any, constraints: Dict) -> Dict[str, Any]:
        """Register a variable with type and constraints."""
        # In a real implementation, you'd validate constraints
        ctx.register_variable(name, type, initial_value, constraints)
        return {
            "registered": True,
            "name": name,
            "type": type
        }
    
    def get_variable(self, ctx: SessionContext, name: str) -> Dict[str, Any]:
        """Get a variable value."""
        value = ctx.get(name)
        return {"value": value, "name": name}
    
    def set_variable(self, ctx: SessionContext, name: str, value: Any) -> Dict[str, Any]:
        """Set a variable value."""
        # In a real implementation, you'd validate against constraints
        ctx.set(name, value)
        return {"updated": True, "name": name}
    
    def set_variable_with_history(self, ctx: SessionContext, name: str, 
                                 value: Any, reason: str) -> Dict[str, Any]:
        """Set variable with history tracking."""
        # Set the value
        ctx.set(name, value)
        
        # Track history (simplified)
        history_key = f"{name}_history"
        history = ctx.get(history_key, [])
        history.append({
            "value": value,
            "reason": reason,
            "timestamp": datetime.now().isoformat()
        })
        ctx.set(history_key, history)
        
        return {
            "updated": True,
            "version": len(history)
        }
    
    def get_variables(self, ctx: SessionContext, names: List[str]) -> Dict[str, Any]:
        """Batch get variables."""
        variables = {}
        for name in names:
            variables[name] = ctx.get(name)
        return {"variables": variables}
    
    def set_variables(self, ctx: SessionContext, updates: Dict[str, Any]) -> Dict[str, Any]:
        """Batch set variables."""
        updated = 0
        failed = 0
        
        for name, value in updates.items():
            try:
                ctx.set(name, value)
                updated += 1
            except Exception:
                failed += 1
        
        return {
            "updated_count": updated,
            "failed_count": failed
        }
    
    # ML operations
    def load_sample_data(self, ctx: SessionContext, dataset: str, 
                        split: float) -> Dict[str, Any]:
        """Load sample dataset."""
        # Simulate loading iris dataset
        if dataset == "iris":
            # Generate fake iris-like data
            total_samples = 150
            train_samples = int(total_samples * split)
            test_samples = total_samples - train_samples
            
            # Store in ML state
            session_id = ctx.session_id
            self.ml_data[session_id] = {
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
                "feature_names": self.ml_data[session_id]["feature_names"]
            }
    
    def preprocess_data(self, ctx: SessionContext, normalize: bool,
                       handle_missing: str, encode_categorical: bool) -> Dict[str, Any]:
        """Preprocess the loaded data."""
        # Simulate preprocessing
        time.sleep(0.5)
        
        return {
            "normalized": normalize,
            "missing_handled": True,
            "categorical_encoded": encode_categorical
        }
    
    def generate_features(self, ctx: SessionContext, method: str,
                         degree: int, interaction_only: bool) -> Dict[str, Any]:
        """Generate polynomial features."""
        session_id = ctx.session_id
        if session_id in self.ml_data:
            original = self.ml_data[session_id]["X_train"].shape[1]
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
    
    def select_features(self, ctx: SessionContext, method: str,
                       k_best: int) -> Dict[str, Any]:
        """Select best features."""
        session_id = ctx.session_id
        if session_id in self.ml_data:
            feature_names = self.ml_data[session_id]["feature_names"]
            # Generate fake feature scores
            scores = np.random.rand(len(feature_names))
            selected = sorted(zip(feature_names, scores), 
                            key=lambda x: x[1], reverse=True)[:k_best]
            
            return {"selected_features": selected}
    
    def train_model(self, ctx: SessionContext, algorithm: str,
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
        
        # Store model
        session_id = ctx.session_id
        self.ml_models[session_id] = {
            "algorithm": algorithm,
            "accuracy": final_accuracy
        }
        
        yield StreamChunk({
            "type": "completed",
            "final_accuracy": final_accuracy,
            "training_time_ms": training_time
        }, is_final=True)
    
    def cross_validate(self, ctx: SessionContext, cv_folds: int) -> Dict[str, Any]:
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
    
    def predict_single(self, ctx: SessionContext, features: Dict[str, float]) -> Dict[str, Any]:
        """Make a single prediction."""
        # Simulate prediction
        prediction = np.random.choice(["setosa", "versicolor", "virginica"])
        confidence = 0.8 + np.random.rand() * 0.2
        
        return {
            "prediction": prediction,
            "confidence": confidence
        }
    
    def predict_batch_with_embeddings(self, ctx: SessionContext, batch_size: int,
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