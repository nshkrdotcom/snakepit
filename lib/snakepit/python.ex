defmodule Snakepit.Python do
  @moduledoc """
  Enhanced Python interop API built on Snakepit V2 architecture.

  Provides universal Python method invocation while maintaining full
  backward compatibility with existing patterns. Uses the enhanced
  Python adapter to enable dynamic calls on any Python library.

  ## Features

  - Dynamic method calls on any Python object/module
  - Object persistence across calls and sessions
  - Framework-agnostic design supporting any Python library
  - Pipeline execution for complex workflows
  - Smart serialization with framework-specific optimizations
  - Full backward compatibility with existing adapters

  ## Usage

      # Configure to use enhanced adapter
      config :snakepit,
        adapter_module: Snakepit.Adapters.EnhancedPython
      
      # Dynamic method calls
      Snakepit.Python.call("pandas.read_csv", %{filepath: "data.csv"})
      Snakepit.Python.call("sklearn.linear_model.LinearRegression", %{}, store_as: "model")
      Snakepit.Python.call("stored.model.fit", %{X: data, y: labels})
      
      # Pipeline execution
      Snakepit.Python.pipeline([
        {:call, "dspy.configure", %{lm: "openai/gpt-3.5-turbo"}},
        {:call, "dspy.Predict", %{signature: "question -> answer"}, store_as: "qa"},
        {:call, "stored.qa.__call__", %{question: "What is Python?"}}
      ])
  """

  @doc """
  Call any Python method dynamically.

  ## Parameters

  - `target` - Python target to call (e.g., "pandas.read_csv", "stored.model.predict")
  - `kwargs` - Keyword arguments for the call (optional)
  - `opts` - Additional options including `:store_as`, `:args`, `:pool`, etc.

  ## Examples

      # Module functions
      Snakepit.Python.call("numpy.array", %{object: [1, 2, 3, 4]})
      
      # Class instantiation
      Snakepit.Python.call("sklearn.ensemble.RandomForestClassifier", %{
        n_estimators: 100
      }, store_as: "classifier")
      
      # Method calls on stored objects
      Snakepit.Python.call("stored.classifier.fit", %{X: training_data, y: labels})
      
      # DSPy integration
      Snakepit.Python.call("dspy.ChainOfThought", %{
        signature: "context, question -> reasoning, answer"
      }, store_as: "cot_program")
  """
  def call(target, kwargs \\ %{}, opts \\ []) do
    args = %{
      target: target,
      kwargs: kwargs
    }

    # Add optional arguments
    args = if opts[:args], do: Map.put(args, :args, opts[:args]), else: args
    args = if opts[:store_as], do: Map.put(args, :store_as, opts[:store_as]), else: args

    pool_opts = Keyword.take(opts, [:pool, :timeout, :session_id])

    case opts[:session_id] do
      nil -> Snakepit.execute("call", args, pool_opts)
      session_id -> Snakepit.execute_in_session(session_id, "call", args, pool_opts)
    end
  end

  @doc """
  Store an object for later retrieval.
  """
  def store(id, value, opts \\ []) do
    args = %{id: id, value: value}
    pool_opts = Keyword.take(opts, [:pool, :timeout, :session_id])

    case opts[:session_id] do
      nil -> Snakepit.execute("store", args, pool_opts)
      session_id -> Snakepit.execute_in_session(session_id, "store", args, pool_opts)
    end
  end

  @doc """
  Retrieve a stored object.
  """
  def retrieve(id, opts \\ []) do
    args = %{id: id}
    pool_opts = Keyword.take(opts, [:pool, :timeout, :session_id])

    case opts[:session_id] do
      nil -> Snakepit.execute("retrieve", args, pool_opts)
      session_id -> Snakepit.execute_in_session(session_id, "retrieve", args, pool_opts)
    end
  end

  @doc """
  List all stored objects.
  """
  def list_stored(opts \\ []) do
    pool_opts = Keyword.take(opts, [:pool, :timeout, :session_id])

    case opts[:session_id] do
      nil -> Snakepit.execute("list_stored", %{}, pool_opts)
      session_id -> Snakepit.execute_in_session(session_id, "list_stored", %{}, pool_opts)
    end
  end

  @doc """
  Delete a stored object.
  """
  def delete_stored(id, opts \\ []) do
    args = %{id: id}
    pool_opts = Keyword.take(opts, [:pool, :timeout, :session_id])

    case opts[:session_id] do
      nil -> Snakepit.execute("delete_stored", args, pool_opts)
      session_id -> Snakepit.execute_in_session(session_id, "delete_stored", args, pool_opts)
    end
  end

  @doc """
  Execute a sequence of calls in a pipeline.

  ## Examples

      Snakepit.Python.pipeline([
        {:call, "pandas.read_csv", %{filepath: "data.csv"}, store_as: "df"},
        {:call, "stored.df.describe", %{}},
        {:call, "sklearn.preprocessing.StandardScaler", %{}, store_as: "scaler"},
        {:call, "stored.scaler.fit_transform", %{X: "stored.df"}}
      ])
      
      # With session affinity
      Snakepit.Python.pipeline([
        {:call, "dspy.configure", %{lm: "openai/gpt-3.5-turbo"}},
        {:call, "dspy.Predict", %{signature: "question -> answer"}, store_as: "qa"},
        {:call, "stored.qa.__call__", %{question: "Hello?"}}
      ], session_id: "my_session")
  """
  def pipeline(steps, opts \\ []) do
    # Convert steps to the format expected by the Python bridge
    formatted_steps =
      Enum.map(steps, fn
        {:call, target, kwargs} ->
          %{target: target, kwargs: kwargs}

        {:call, target, kwargs, step_opts} ->
          %{target: target, kwargs: kwargs}
          |> Map.merge(Map.new(step_opts))
      end)

    args = %{steps: formatted_steps}
    pool_opts = Keyword.take(opts, [:pool, :timeout, :session_id])

    case opts[:session_id] do
      nil -> Snakepit.execute("pipeline", args, pool_opts)
      session_id -> Snakepit.execute_in_session(session_id, "pipeline", args, pool_opts)
    end
  end

  @doc """
  Inspect Python objects and get metadata.

  ## Examples

      Snakepit.Python.inspect("numpy.array")
      Snakepit.Python.inspect("stored.my_model")
  """
  def inspect(target, opts \\ []) do
    args = %{target: target}
    pool_opts = Keyword.take(opts, [:pool, :timeout, :session_id])

    case opts[:session_id] do
      nil -> Snakepit.execute("inspect", args, pool_opts)
      session_id -> Snakepit.execute_in_session(session_id, "inspect", args, pool_opts)
    end
  end

  @doc """
  Configure a Python framework with framework-specific optimizations.

  ## Examples

      # DSPy with Gemini
      Snakepit.Python.configure("dspy", %{
        provider: "google",
        model: "gemini-2.5-flash-lite", 
        api_key: System.get_env("GEMINI_API_KEY")
      })
      
      # Generic framework configuration
      Snakepit.Python.configure("transformers", %{
        model_cache_dir: "/tmp/models"
      })
  """
  def configure(framework, config, opts \\ []) do
    call("#{framework}.configure", config, opts)
  end

  @doc """
  Create a session-scoped context for related operations.

  Returns a session ID that can be used for session-affinity calls.
  All objects stored within a session are automatically cleaned up
  when the session expires.

  ## Examples

      session_id = Snakepit.Python.create_session()
      
      Snakepit.Python.call("dspy.configure", %{...}, session_id: session_id)
      Snakepit.Python.call("dspy.Predict", %{...}, store_as: "qa", session_id: session_id)
      Snakepit.Python.call("stored.qa.__call__", %{...}, session_id: session_id)
  """
  def create_session(opts \\ []) do
    session_id = "python_session_#{System.unique_integer([:positive])}"

    # Initialize session with a ping to ensure worker assignment
    case call("ping", %{}, [session_id: session_id] ++ opts) do
      {:ok, _} -> session_id
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get enhanced bridge information and capabilities.
  """
  def info(opts \\ []) do
    pool_opts = Keyword.take(opts, [:pool, :timeout])
    Snakepit.execute("ping", %{}, pool_opts)
  end

  @doc """
  Load a pandas DataFrame from various sources.

  ## Examples

      # CSV file
      Snakepit.Python.load_dataframe(:csv, %{filepath: "data.csv"}, store_as: "df")
      
      # JSON file
      Snakepit.Python.load_dataframe(:json, %{path: "data.json"}, store_as: "df")
      
      # SQL query
      Snakepit.Python.load_dataframe(:sql, %{
        sql: "SELECT * FROM users",
        con: "sqlite:///database.db"
      }, store_as: "users")
  """
  def load_dataframe(source_type, params, opts \\ []) do
    target =
      case source_type do
        :csv -> "pandas.read_csv"
        :json -> "pandas.read_json"
        :sql -> "pandas.read_sql"
        :excel -> "pandas.read_excel"
        :parquet -> "pandas.read_parquet"
        _ -> raise ArgumentError, "Unsupported source type: #{source_type}"
      end

    call(target, params, opts)
  end

  @doc """
  Create and configure machine learning models.

  ## Examples

      # Random Forest
      Snakepit.Python.create_model(:random_forest, %{
        n_estimators: 100,
        random_state: 42
      }, store_as: "rf_model")
      
      # Linear Regression
      Snakepit.Python.create_model(:linear_regression, %{}, store_as: "lr_model")
      
      # Neural Network
      Snakepit.Python.create_model(:mlp, %{
        hidden_layer_sizes: [100, 50],
        max_iter: 1000
      }, store_as: "nn_model")
  """
  def create_model(model_type, params \\ %{}, opts \\ []) do
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
        _ -> raise ArgumentError, "Unsupported model type: #{model_type}"
      end

    call(target, params, opts)
  end

  @doc """
  Train a stored model with data.

  ## Examples

      # Train with stored DataFrame
      Snakepit.Python.train_model("my_model", %{
        X: "stored.X_train",
        y: "stored.y_train"
      })
      
      # Train with direct data
      Snakepit.Python.train_model("my_model", %{
        X: training_features,
        y: training_labels
      })
  """
  def train_model(model_id, data, opts \\ []) do
    call("stored.#{model_id}.fit", data, opts)
  end

  @doc """
  Make predictions with a trained model.

  ## Examples

      # Predict with stored data
      Snakepit.Python.predict("my_model", %{X: "stored.X_test"}, store_as: "predictions")
      
      # Predict with direct data
      Snakepit.Python.predict("my_model", %{X: test_features}, store_as: "predictions")
  """
  def predict(model_id, data, opts \\ []) do
    call("stored.#{model_id}.predict", data, opts)
  end

  @doc """
  Create and configure DSPy programs with simplified syntax.

  ## Examples

      # Simple Q&A program
      Snakepit.Python.create_dspy_program(:predict, %{
        signature: "question -> answer"
      }, store_as: "qa")
      
      # Chain of Thought program
      Snakepit.Python.create_dspy_program(:chain_of_thought, %{
        signature: "context, question -> reasoning, answer"
      }, store_as: "cot")
      
      # Custom program with multiple steps
      class_definition = ~S'''
        class CustomProgram(dspy.Module):
            def __init__(self):
                super().__init__()
                self.generate_query = dspy.Predict("context -> query")
                self.answer = dspy.Predict("query, context -> answer")
            
            def forward(self, context):
                query = self.generate_query(context=context)
                answer = self.answer(query=query.query, context=context)
                return answer
      '''
      
      Snakepit.Python.create_dspy_program(:module, %{
        class_definition: class_definition
      }, store_as: "custom_program")
  """
  def create_dspy_program(program_type, params, opts \\ []) do
    target =
      case program_type do
        :predict ->
          "dspy.Predict"

        :chain_of_thought ->
          "dspy.ChainOfThought"

        :react ->
          "dspy.ReAct"

        :retrieve ->
          "dspy.Retrieve"

        :module ->
          # For custom modules, execute the class definition first
          class_def = Map.get(params, :class_definition)

          if class_def do
            call("exec", %{code: class_def}, opts)
            "CustomProgram"
          else
            raise ArgumentError, "module type requires class_definition parameter"
          end

        _ ->
          raise ArgumentError, "Unsupported DSPy program type: #{program_type}"
      end

    # Remove class_definition from params for actual instantiation
    clean_params = Map.delete(params, :class_definition)
    call(target, clean_params, opts)
  end

  @doc """
  Execute a DSPy program with inputs.

  ## Examples

      # Simple execution
      Snakepit.Python.execute_dspy("qa", %{question: "What is Elixir?"})
      
      # With context
      Snakepit.Python.execute_dspy("cot", %{
        context: "Elixir is a functional programming language...",
        question: "What are the main features?"
      })
  """
  def execute_dspy(program_id, inputs, opts \\ []) do
    call("stored.#{program_id}.__call__", inputs, opts)
  end

  @doc """
  Configure DSPy with various language model providers.

  ## Examples

      # OpenAI GPT
      Snakepit.Python.configure_dspy(:openai, %{
        model: "gpt-4",
        api_key: System.get_env("OPENAI_API_KEY")
      })
      
      # Google Gemini
      Snakepit.Python.configure_dspy(:gemini, %{
        model: "gemini-2.5-flash-lite",
        api_key: System.get_env("GEMINI_API_KEY")
      })
      
      # Anthropic Claude
      Snakepit.Python.configure_dspy(:anthropic, %{
        model: "claude-3-sonnet-20240229",
        api_key: System.get_env("ANTHROPIC_API_KEY")
      })
  """
  def configure_dspy(provider, config, opts \\ []) do
    case provider do
      :openai ->
        model = Map.get(config, :model, "gpt-3.5-turbo")
        api_key = Map.get(config, :api_key)

        call(
          "dspy.configure",
          %{
            lm:
              call("dspy.LM", %{
                model: "openai/#{model}",
                api_key: api_key
              })
          },
          opts
        )

      :gemini ->
        model = Map.get(config, :model, "gemini-2.5-flash-lite")
        api_key = Map.get(config, :api_key)

        configure(
          "dspy",
          %{
            provider: "google",
            model: model,
            api_key: api_key
          },
          opts
        )

      :anthropic ->
        model = Map.get(config, :model, "claude-3-sonnet-20240229")
        api_key = Map.get(config, :api_key)

        call(
          "dspy.configure",
          %{
            lm:
              call("dspy.LM", %{
                model: "anthropic/#{model}",
                api_key: api_key
              })
          },
          opts
        )

      _ ->
        raise ArgumentError, "Unsupported DSPy provider: #{provider}"
    end
  end
end
