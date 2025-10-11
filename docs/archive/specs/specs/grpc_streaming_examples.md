# gRPC Streaming Examples & Use Cases

## Overview

This document outlines practical streaming examples that showcase the core value proposition of the gRPC bridge redesign. These examples demonstrate capabilities impossible with the current stdin/stdout approach.

## Streaming Categories

### 1. Server Streaming (Most Common)
**Pattern**: Single request → Multiple response chunks
**Use Case**: Long-running computations, progressive results

### 2. Client Streaming (Less Common)
**Pattern**: Multiple request chunks → Single response  
**Use Case**: Large dataset uploads, incremental data processing

### 3. Bidirectional Streaming (Advanced)
**Pattern**: Multiple requests ↔ Multiple responses
**Use Case**: Real-time interactions, continuous feedback loops

## Core Streaming Examples

### Example 1: ML Model Inference with Progressive Results

**Scenario**: Run inference on a batch of images, stream results as they complete

```python
# Python gRPC server
def ExecuteStream(self, request, context):
    if request.command == "batch_inference":
        model_path = request.args["model_path"].decode()
        image_paths = json.loads(request.args["image_paths"].decode())
        
        model = load_model(model_path)
        
        for i, image_path in enumerate(image_paths):
            # Process each image
            image = load_image(image_path)
            prediction = model.predict(image)
            
            # Stream individual result
            yield snakepit_pb2.StreamResponse(
                is_final=False,
                chunk={
                    "image_index": str(i).encode(),
                    "image_path": image_path.encode(),
                    "prediction": json.dumps(prediction).encode(),
                    "confidence": str(prediction.confidence).encode()
                },
                timestamp=time.time_ns()
            )
        
        # Final summary
        yield snakepit_pb2.StreamResponse(
            is_final=True,
            chunk={
                "total_processed": str(len(image_paths)).encode(),
                "batch_complete": b"true"
            },
            timestamp=time.time_ns()
        )
```

```elixir
# Elixir client
def batch_inference_example() do
  worker = get_worker()
  
  # Stream results as they arrive
  Snakepit.GRPCWorker.execute_stream(
    worker,
    "batch_inference", 
    %{
      model_path: "/models/resnet50.pkl",
      image_paths: Jason.encode!(["img1.jpg", "img2.jpg", "img3.jpg"])
    },
    fn chunk ->
      if chunk["is_final"] do
        IO.puts("✅ Batch complete: #{chunk["total_processed"]} images")
      else
        IO.puts("📸 Processed #{chunk["image_path"]}: #{chunk["confidence"]}% confidence")
      end
    end
  )
end
```

### Example 2: Large Dataset Processing with Progress Updates

**Scenario**: Process a 1GB CSV file, stream progress and intermediate results

```python
def ExecuteStream(self, request, context):
    if request.command == "process_large_dataset":
        file_path = request.args["file_path"].decode()
        chunk_size = int(request.args.get("chunk_size", b"1000").decode())
        
        total_rows = count_rows(file_path)
        processed = 0
        
        for chunk_df in pd.read_csv(file_path, chunksize=chunk_size):
            # Process chunk
            result = process_dataframe_chunk(chunk_df)
            processed += len(chunk_df)
            
            # Stream progress + partial results
            yield snakepit_pb2.StreamResponse(
                is_final=False,
                chunk={
                    "processed_rows": str(processed).encode(),
                    "total_rows": str(total_rows).encode(),
                    "progress_percent": str(round(processed/total_rows*100, 1)).encode(),
                    "chunk_summary": json.dumps(result.summary()).encode(),
                    "chunk_stats": json.dumps(result.stats()).encode()
                }
            )
        
        # Final aggregated results
        yield snakepit_pb2.StreamResponse(
            is_final=True,
            chunk={
                "final_stats": json.dumps(aggregate_all_chunks()).encode(),
                "processing_complete": b"true"
            }
        )
```

```elixir
def large_dataset_example() do
  worker = get_worker()
  
  Snakepit.GRPCWorker.execute_stream(
    worker,
    "process_large_dataset",
    %{file_path: "/data/huge_dataset.csv", chunk_size: "5000"},
    fn chunk ->
      if chunk["is_final"] do
        IO.puts("🎉 Processing complete!")
        IO.puts("Final stats: #{chunk["final_stats"]}")
      else
        progress = chunk["progress_percent"]
        IO.puts("📊 Progress: #{progress}% (#{chunk["processed_rows"]}/#{chunk["total_rows"]} rows)")
      end
    end
  )
end
```

### Example 3: Real-time Log Analysis

**Scenario**: Tail a log file and stream analysis results in real-time

```python
def ExecuteStream(self, request, context):
    if request.command == "tail_and_analyze":
        log_path = request.args["log_path"].decode()
        patterns = json.loads(request.args["error_patterns"].decode())
        
        # Tail the file
        with open(log_path, 'r') as f:
            f.seek(0, 2)  # Go to end
            
            while True:
                line = f.readline()
                if not line:
                    time.sleep(0.1)
                    continue
                
                # Analyze line
                analysis = analyze_log_line(line, patterns)
                if analysis["has_match"]:
                    yield snakepit_pb2.StreamResponse(
                        is_final=False,
                        chunk={
                            "timestamp": str(time.time()).encode(),
                            "log_line": line.encode(),
                            "severity": analysis["severity"].encode(),
                            "pattern_matched": analysis["pattern"].encode(),
                            "context": json.dumps(analysis["context"]).encode()
                        }
                    )
```

```elixir
def realtime_log_analysis() do
  worker = get_worker()
  
  Snakepit.GRPCWorker.execute_stream(
    worker,
    "tail_and_analyze",
    %{
      log_path: "/var/log/app.log",
      error_patterns: Jason.encode!(["ERROR", "FATAL", "Exception"])
    },
    fn chunk ->
      severity = chunk["severity"]
      pattern = chunk["pattern_matched"]
      IO.puts("🚨 [#{severity}] #{pattern}: #{String.slice(chunk["log_line"], 0, 100)}...")
    end
  )
end
```

### Example 4: Distributed Training Progress

**Scenario**: Monitor distributed ML training across multiple nodes

```python
def ExecuteStream(self, request, context):
    if request.command == "distributed_training":
        config = json.loads(request.args["training_config"].decode())
        
        trainer = DistributedTrainer(config)
        trainer.start()
        
        for epoch_results in trainer.train_with_progress():
            yield snakepit_pb2.StreamResponse(
                is_final=False,
                chunk={
                    "epoch": str(epoch_results.epoch).encode(),
                    "train_loss": str(epoch_results.train_loss).encode(),
                    "val_loss": str(epoch_results.val_loss).encode(),
                    "train_acc": str(epoch_results.train_accuracy).encode(),
                    "val_acc": str(epoch_results.val_accuracy).encode(),
                    "learning_rate": str(epoch_results.lr).encode(),
                    "time_elapsed": str(epoch_results.time_elapsed).encode(),
                    "gpu_memory": json.dumps(epoch_results.gpu_stats).encode()
                }
            )
        
        # Training complete
        yield snakepit_pb2.StreamResponse(
            is_final=True,
            chunk={
                "final_model_path": trainer.save_model().encode(),
                "total_epochs": str(trainer.epochs_completed).encode(),
                "best_val_acc": str(trainer.best_val_accuracy).encode()
            }
        )
```

### Example 5: Financial Data Pipeline

**Scenario**: Stream real-time stock analysis with multiple indicators

```python
def ExecuteStream(self, request, context):
    if request.command == "realtime_stock_analysis":
        symbols = json.loads(request.args["symbols"].decode())
        indicators = json.loads(request.args["indicators"].decode())
        
        stream = MarketDataStream(symbols)
        analyzer = TechnicalAnalyzer(indicators)
        
        for market_data in stream:
            analysis = analyzer.analyze(market_data)
            
            yield snakepit_pb2.StreamResponse(
                is_final=False,
                chunk={
                    "symbol": market_data.symbol.encode(),
                    "price": str(market_data.price).encode(),
                    "volume": str(market_data.volume).encode(),
                    "rsi": str(analysis.rsi).encode(),
                    "macd": str(analysis.macd).encode(),
                    "signal": analysis.trading_signal.encode(),
                    "timestamp": str(market_data.timestamp).encode()
                }
            )
```

## Implementation Timeline

### Phase 1: Basic Streaming Infrastructure (Day 1-2)
- [ ] Protocol buffer definitions with streaming support
- [ ] Basic Elixir streaming client wrapper
- [ ] Python streaming server foundation
- [ ] Simple "ping stream" example (heartbeat every second)

### Phase 2: ML/Data Processing Examples (Day 3-4)
- [ ] **Example 1**: Batch inference streaming
- [ ] **Example 2**: Large dataset processing with progress
- [ ] Performance comparison vs current blocking approach

### Phase 3: Real-time Examples (Day 5-6)
- [ ] **Example 3**: Real-time log analysis
- [ ] **Example 4**: Training progress monitoring
- [ ] **Example 5**: Financial data pipeline
- [ ] Documentation and integration tests

## Example Applications

### Data Science Workflows
```elixir
# Process multiple datasets concurrently with progress tracking
datasets = ["sales_q1.csv", "sales_q2.csv", "sales_q3.csv", "sales_q4.csv"]

tasks = Enum.map(datasets, fn dataset ->
  Task.async(fn ->
    Snakepit.GRPCWorker.execute_stream(
      worker, 
      "process_large_dataset", 
      %{file_path: dataset},
      &handle_progress/1
    )
  end)
end)

Task.await_many(tasks)
```

### ML Model Serving
```elixir
# Real-time inference pipeline
Snakepit.GRPCWorker.execute_stream(
  worker,
  "realtime_inference",
  %{model: "fraud_detection", input_stream: "transactions"},
  fn result ->
    if result["fraud_probability"] > 0.8 do
      alert_fraud_team(result)
    end
  end
)
```

### DevOps Monitoring
```elixir
# Monitor multiple log files simultaneously
log_files = ["/var/log/app.log", "/var/log/db.log", "/var/log/nginx.log"]

Enum.each(log_files, fn log_file ->
  Task.start(fn ->
    Snakepit.GRPCWorker.execute_stream(
      worker,
      "tail_and_analyze", 
      %{log_path: log_file},
      &handle_log_alert/1
    )
  end)
end)
```

## Success Metrics

### Functional Requirements
- [ ] Can stream ML inference results progressively
- [ ] Can process large datasets with real-time progress updates
- [ ] Can handle real-time data streams (logs, financial data, etc.)
- [ ] Maintains session affinity during streaming operations

### Performance Requirements
- [ ] Sub-100ms latency for streaming chunk delivery
- [ ] Can handle 1000+ chunks per stream without memory leaks
- [ ] Graceful handling of slow consumers (backpressure)
- [ ] Proper cleanup when streams are cancelled

### Developer Experience
- [ ] Simple callback-based API in Elixir
- [ ] Clear examples for each streaming pattern
- [ ] Good error messages when streams fail
- [ ] Easy debugging of streaming operations

## Migration Benefits Over Current Approach

**Current Limitations:**
- ❌ No way to get progress updates on long operations
- ❌ Large responses consume memory until complete
- ❌ No real-time data processing capabilities
- ❌ Poor user experience for long-running tasks

**gRPC Streaming Benefits:**
- ✅ Progressive results and real-time feedback
- ✅ Constant memory usage regardless of response size
- ✅ True real-time processing capabilities
- ✅ Better user experience with progress indicators
- ✅ Can cancel long-running operations mid-stream

---

**Bottom Line**: These streaming examples demonstrate that gRPC isn't just "better MessagePack" - it enables entirely new classes of applications that are impossible with the current architecture.