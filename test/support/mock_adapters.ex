defmodule Snakepit.TestAdapters.MockAdapter do
  @moduledoc """
  Basic mock adapter for testing Snakepit core functionality.
  
  Implements the cognitive-ready Snakepit.Adapter behavior with simple
  mock responses for testing purposes.
  """
  
  @behaviour Snakepit.Adapter
  require Logger

  # Required callbacks

  @impl Snakepit.Adapter
  def execute(command, args, _opts) do
    # Simulate basic command execution
    case command do
      "ping" -> {:ok, "pong"}
      "echo" -> {:ok, Map.get(args, "message", "hello")}
      "error" -> {:error, "mock error"}
      "slow" -> 
        Process.sleep(100)
        {:ok, "completed"}
      _ -> {:ok, %{command: command, args: args}}
    end
  end

  # Optional callbacks with defaults

  @impl Snakepit.Adapter
  def execute_stream(_command, _args, callback_fn, _opts) do
    # Mock streaming - send a few messages
    callback_fn.(%{chunk: 1, data: "first"})
    callback_fn.(%{chunk: 2, data: "second"}) 
    callback_fn.(%{chunk: 3, data: "final"})
    :ok
  end

  @impl Snakepit.Adapter
  def uses_grpc?, do: false

  @impl Snakepit.Adapter
  def supports_streaming?, do: true

  @impl Snakepit.Adapter
  def init(_config) do
    {:ok, %{initialized_at: DateTime.utc_now()}}
  end

  @impl Snakepit.Adapter
  def terminate(_reason, _state) do
    :ok
  end

  @impl Snakepit.Adapter
  def start_worker(_adapter_state, worker_id) do
    # Mock worker process - just return a fake PID
    pid = spawn(fn -> 
      receive do
        :stop -> :ok
      after
        30_000 -> :ok
      end
    end)
    
    Logger.debug("Mock adapter started worker #{worker_id}: #{inspect(pid)}")
    {:ok, pid}
  end

  @impl Snakepit.Adapter
  def get_cognitive_metadata do
    Snakepit.Adapter.default_cognitive_metadata()
    |> Map.merge(%{
      adapter_type: :mock,
      test_mode: true,
      mock_features: [:basic_commands, :streaming, :error_simulation]
    })
  end

  @impl Snakepit.Adapter
  def report_performance_metrics(metrics, context) do
    Logger.debug("Mock adapter received metrics: #{inspect(metrics)} context: #{inspect(context)}")
    :ok
  end
end

defmodule Snakepit.TestAdapters.MockGRPCAdapter do
  @moduledoc """
  Mock gRPC adapter for testing gRPC-specific functionality.
  """
  
  @behaviour Snakepit.Adapter
  require Logger

  # Required callbacks

  @impl Snakepit.Adapter
  def execute(command, args, _opts) do
    # Simulate gRPC command execution with more realistic responses
    case command do
      "ping" -> {:ok, %{response: "pong", grpc_metadata: %{server: "mock"}}}
      "create_program" -> 
        program_id = "mock_program_#{:rand.uniform(1000)}"
        {:ok, %{
          program_id: program_id,
          signature: Map.get(args, :signature, "input -> output"),
          created_at: DateTime.utc_now(),
          program_type: "predict"
        }}
      "execute_program" ->
        {:ok, %{
          result: "mock execution result",
          program_id: Map.get(args, :program_id, "mock_program"),
          execution_time: 42
        }}
      "discover_schema" ->
        {:ok, %{
          schema: %{
            input_fields: ["query"],
            output_fields: ["response"],
            field_types: %{query: "string", response: "string"}
          },
          cached: false
        }}
      "error" -> {:error, %{grpc_code: 3, message: "mock gRPC error"}}
      _ -> {:ok, %{command: command, args: args, grpc: true}}
    end
  end

  # Optional callbacks

  @impl Snakepit.Adapter
  def execute_stream(command, _args, callback_fn, _opts) do
    case command do
      "streaming_inference" ->
        # Simulate streaming inference responses
        for i <- 1..3 do
          callback_fn.(%{
            chunk_id: i,
            partial_result: "chunk_#{i}",
            is_final: i == 3
          })
          Process.sleep(10) # Small delay to simulate network
        end
        :ok
      _ ->
        callback_fn.(%{error: "Command #{command} does not support streaming"})
        {:error, :streaming_not_supported}
    end
  end

  @impl Snakepit.Adapter
  def uses_grpc?, do: true

  @impl Snakepit.Adapter
  def supports_streaming?, do: true

  @impl Snakepit.Adapter
  def init(config) do
    port = Keyword.get(config, :port, 50051)
    {:ok, %{
      initialized_at: DateTime.utc_now(),
      grpc_port: port,
      connection_pool: :mock_pool
    }}
  end

  @impl Snakepit.Adapter
  def terminate(_reason, state) do
    Logger.debug("Mock gRPC adapter terminating, was using port #{state.grpc_port}")
    :ok
  end

  @impl Snakepit.Adapter
  def start_worker(_adapter_state, worker_id) do
    # Mock gRPC worker
    pid = spawn(fn ->
      receive do
        :stop -> :ok
      after
        30_000 -> :ok
      end
    end)
    
    Logger.debug("Mock gRPC adapter started worker #{worker_id} (adapter state not used)")
    {:ok, pid}
  end

  @impl Snakepit.Adapter
  def get_cognitive_metadata do
    Snakepit.Adapter.default_cognitive_metadata()
    |> Map.merge(%{
      adapter_type: :mock_grpc,
      test_mode: true,
      communication_protocol: :grpc,
      mock_features: [:program_management, :schema_discovery, :streaming_inference]
    })
  end

  @impl Snakepit.Adapter
  def report_performance_metrics(metrics, context) do
    # Mock some gRPC-specific metrics tracking
    Logger.debug("Mock gRPC adapter metrics: #{inspect(metrics)} context: #{inspect(context)}")
    :ok
  end

  # Test-specific helpers
  
  def simulate_latency(command) do
    case command do
      "slow_operation" -> Process.sleep(200)
      "very_slow" -> Process.sleep(500)
      _ -> :ok
    end
  end
  
  def simulate_error_rate(command, error_rate \\ 0.1) do
    if :rand.uniform() < error_rate do
      {:error, "Simulated #{command} failure"}
    else
      :ok
    end
  end
end

defmodule Snakepit.TestAdapters.FailingAdapter do
  @moduledoc """
  Mock adapter that fails initialization - useful for testing error conditions.
  """
  
  @behaviour Snakepit.Adapter
  require Logger

  # Required callback (will never be called due to init failure)
  @impl Snakepit.Adapter  
  def execute(_command, _args, _opts) do
    {:error, "Adapter failed during initialization"}
  end

  # This adapter intentionally fails during init
  @impl Snakepit.Adapter
  def init(_config) do
    {:error, "Mock initialization failure"}
  end

  @impl Snakepit.Adapter
  def uses_grpc?, do: false

  @impl Snakepit.Adapter
  def supports_streaming?, do: false

  @impl Snakepit.Adapter
  def get_cognitive_metadata do
    %{adapter_type: :failing_mock, test_mode: true}
  end
end

defmodule Snakepit.TestAdapters.SessionAffinityAdapter do
  @moduledoc """
  Mock adapter that demonstrates session affinity features.
  """
  
  @behaviour Snakepit.Adapter
  require Logger

  # Required callbacks

  @impl Snakepit.Adapter
  def execute(command, args, opts) do
    session_id = Keyword.get(opts, :session_id)
    worker_id = Keyword.get(opts, :worker_id, "unknown")
    
    case command do
      "get_session_info" ->
        {:ok, %{
          session_id: session_id,
          worker_id: worker_id,
          affinity_active: session_id != nil
        }}
      "store_data" ->
        # Mock storing data with session affinity
        data = Map.get(args, "data", "default")
        {:ok, %{stored: data, session_id: session_id, worker_id: worker_id}}
      _ ->
        {:ok, %{command: command, session_id: session_id, worker_id: worker_id}}
    end
  end

  # Optional callbacks with session enhancement

  def get_session_worker(session_id) do
    # Mock session affinity - return a consistent worker for the same session
    worker_id = "worker_#{:erlang.phash2(session_id, 3) + 1}"
    {:ok, worker_id}
  end

  def store_session_worker(session_id, worker_id) do
    Logger.debug("Mock storing session affinity: #{session_id} -> #{worker_id}")
    :ok
  end

  def enhance_session_args(session_id, _command, args) do
    enhanced = Map.merge(args, %{
      session_id: session_id,
      session_context: %{
        created_at: DateTime.utc_now(),
        enhanced_by: __MODULE__
      }
    })
    {:ok, enhanced}
  end

  def handle_session_response(session_id, command, _args, response) do
    # Mock session response enhancement
    case response do
      {:ok, data} when is_map(data) ->
        enhanced_data = Map.merge(data, %{
          session_processed: true,
          session_id: session_id,
          command: command
        })
        {:ok, {:ok, enhanced_data}}
      other ->
        {:ok, other}
    end
  end
  
  # Standard adapter callbacks

  @impl Snakepit.Adapter
  def uses_grpc?, do: false

  @impl Snakepit.Adapter 
  def supports_streaming?, do: false

  @impl Snakepit.Adapter
  def init(_config) do
    {:ok, %{session_data: %{}}}
  end

  @impl Snakepit.Adapter
  def get_cognitive_metadata do
    %{
      adapter_type: :session_affinity_mock,
      test_mode: true,
      features: [:session_enhancement, :worker_affinity]
    }
  end
end