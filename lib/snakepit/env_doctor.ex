defmodule Snakepit.EnvDoctor do
  @moduledoc """
  Environment diagnostics for the Python bridge.

  Provides both a Mix task integration (`mix snakepit.doctor`) and runtime
  guardrails via `ensure_python!/1`.
  """

  import Bitwise

  @type check_result :: %{name: atom(), status: :ok | :warning | :error, message: String.t()}

  @default_checks [
    :python_exec,
    :grpc_import,
    :venv,
    :venv_py313,
    :grpc_server,
    :adapter_imports,
    :grpc_port
  ]

  @runtime_checks [:python_exec, :grpc_import, :grpc_server, :adapter_imports]
  alias Snakepit.Adapters.GRPCPython
  alias Snakepit.Config
  alias Snakepit.Defaults
  alias Snakepit.PythonRuntime

  @doc """
  Run the full doctor suite. Returns `{:ok, results}` or `{:error, results}`.
  """
  @spec run(Keyword.t()) :: {:ok, [check_result()]} | {:error, [check_result()]}
  def run(opts \\ []) do
    run_checks(@default_checks, opts)
  end

  @doc """
  Ensure the Python runtime is ready. Raises if any critical check fails.
  """
  @spec ensure_python!(Keyword.t()) :: :ok | no_return()
  def ensure_python!(opts \\ []) do
    case run_checks(@runtime_checks, opts) do
      {:ok, _results} ->
        :ok

      {:error, results} ->
        message =
          results
          |> Enum.filter(&(&1.status == :error))
          |> Enum.map_join("\n", &"* #{&1.message}")

        raise RuntimeError,
              "Python environment is not ready:\n" <> message
    end
  end

  defp run_checks(names, opts) do
    state = build_state(opts)

    {results, status} =
      Enum.reduce(names, {[], :ok}, fn name, {acc, acc_status} ->
        result = run_check(name, state)
        new_status = if result.status == :error, do: :error, else: acc_status
        {[result | acc], new_status}
      end)

    results = Enum.reverse(results)

    case status do
      :ok -> {:ok, results}
      :error -> {:error, results}
    end
  end

  defp build_state(opts) do
    project_root =
      opts[:project_root] ||
        Application.get_env(:snakepit, :bootstrap_project_root) ||
        File.cwd!()

    python_runtime = PythonRuntime.config()
    python_path = opts[:python_path] || GRPCPython.executable_path()

    runner =
      opts[:runner] ||
        Application.get_env(:snakepit, :env_doctor_runner, Snakepit.Bootstrap.Runner.System)

    require_python_313? =
      Keyword.get(
        opts,
        :require_python_313?,
        Application.get_env(:snakepit, :require_python_313?, false)
      )

    grpc_listener = resolve_grpc_listener(opts)

    %{
      project_root: project_root,
      python_path: python_path,
      python_runtime: python_runtime,
      runner: runner,
      require_python_313?: require_python_313?,
      grpc_listener: grpc_listener
    }
  end

  defp run_check(:python_exec, state) do
    case python_path_for_check(state) do
      {:ok, path} -> ok(:python_exec, "Python executable found at #{path}")
      {:error, message} -> error(:python_exec, message)
    end
  end

  defp run_check(:grpc_import, state) do
    case python_path_for_check(state) do
      {:ok, _} ->
        run_python(
          state,
          ["-c", "import grpc"],
          :grpc_import,
          "Importing grpc failed. Run mix snakepit.setup (or make bootstrap)."
        )

      {:error, message} ->
        error(:grpc_import, message)
    end
  end

  defp run_check(:venv, %{project_root: root, python_runtime: runtime}) do
    if PythonRuntime.managed?(runtime) do
      warning(:venv, "Managed Python enabled; .venv check skipped.")
    else
      case File.dir?(Path.join(root, ".venv")) do
        true ->
          ok(:venv, ".venv present (Python 3.12)")

        false ->
          error(
            :venv,
            ".venv missing. Run mix snakepit.setup (or make bootstrap) to create the default Python environment."
          )
      end
    end
  end

  defp run_check(:venv_py313, %{
         project_root: root,
         require_python_313?: required?,
         python_runtime: runtime
       }) do
    if PythonRuntime.managed?(runtime) do
      warning(:venv_py313, "Managed Python enabled; .venv-py313 check skipped.")
    else
      path = Path.join(root, ".venv-py313")

      cond do
        File.dir?(path) ->
          ok(:venv_py313, ".venv-py313 ready (Python 3.13)")

        required? ->
          error(
            :venv_py313,
            ".venv-py313 missing. Run mix snakepit.setup (or make bootstrap) to enable free-threaded tests."
          )

        true ->
          warning(
            :venv_py313,
            ".venv-py313 missing. Thread-profile tests will be skipped until you run mix snakepit.setup (or make bootstrap)."
          )
      end
    end
  end

  defp run_check(:grpc_server, state) do
    case python_path_for_check(state) do
      {:ok, _} ->
        case grpc_server_root(state) do
          nil ->
            error(
              :grpc_server,
              "priv/python/grpc_server.py missing. Run mix snakepit.setup (or make bootstrap) to regenerate assets."
            )

          root ->
            script = Path.join(root, "priv/python/grpc_server.py")
            args = [script, "--health-check"] ++ default_adapter_args()

            run_python(
              state,
              args,
              :grpc_server,
              "gRPC server health check failed. Regenerate stubs or reinstall deps.",
              root
            )
        end

      {:error, message} ->
        error(:grpc_server, message)
    end
  end

  defp run_check(:adapter_imports, state) do
    case python_path_for_check(state) do
      {:ok, python_path} ->
        adapters = configured_adapter_paths()

        case adapters do
          [] ->
            warning(
              :adapter_imports,
              "No adapter configured; default ShowcaseAdapter will be used."
            )

          _ ->
            check_adapter_imports(state, python_path, adapters)
        end

      {:error, message} ->
        error(:adapter_imports, message)
    end
  end

  defp run_check(:grpc_port, %{grpc_listener: {:error, reason}}) do
    error(:grpc_port, "Invalid gRPC listener config: #{inspect(reason)}")
  end

  defp run_check(:grpc_port, %{grpc_listener: %{mode: :internal}}) do
    ok(:grpc_port, "Internal gRPC listener uses port 0 (ephemeral)")
  end

  defp run_check(:grpc_port, %{grpc_listener: %{mode: :external, port: port}}) do
    check_grpc_port_available(port)
  end

  defp run_check(:grpc_port, %{
         grpc_listener: %{mode: :external_pool, base_port: base_port, pool_size: pool_size}
       })
       when is_integer(base_port) and is_integer(pool_size) do
    ports = base_port..(base_port + pool_size - 1)

    case Enum.find(ports, &port_available?/1) do
      nil ->
        error(
          :grpc_port,
          "No available ports in pool #{base_port}-#{base_port + pool_size - 1}. " <>
            "Adjust grpc_listener config."
        )

      port ->
        ok(:grpc_port, "Port #{port} available for pooled gRPC listener")
    end
  end

  defp run_check(:grpc_port, %{grpc_listener: %{mode: :external_pool}}) do
    error(:grpc_port, "Invalid grpc_listener pool configuration")
  end

  defp run_check(:grpc_port, _state) do
    warning(:grpc_port, "Unable to resolve gRPC listener configuration")
  end

  defp resolve_grpc_listener(opts) do
    cond do
      Keyword.has_key?(opts, :grpc_listener) ->
        opts[:grpc_listener]

      Keyword.has_key?(opts, :grpc_port) ->
        host = opts[:grpc_host] || Defaults.grpc_internal_host()
        port = opts[:grpc_port]

        if port in [0, "0"] do
          %{mode: :internal, host: host, bind_host: host, port: 0}
        else
          %{mode: :external, host: host, bind_host: host, port: port}
        end

      true ->
        case Config.grpc_listener_config() do
          {:ok, config} -> config
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp check_grpc_port_available(port) do
    case :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        ok(:grpc_port, "Port #{port} available for the Elixir gRPC server")

      {:error, :eaddrinuse} ->
        error(
          :grpc_port,
          "Port #{port} is already in use. Stop the conflicting service or adjust the listener config."
        )

      {:error, reason} ->
        warning(:grpc_port, "Unable to verify port #{port}: #{inspect(reason)}")
    end
  end

  defp port_available?(port) do
    case :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  end

  defp run_python(state, args, name, failure_message, root_override \\ nil) do
    %{python_path: path, runner: runner, project_root: root} = state
    root = root_override || root

    case runner.cmd(path, args, cd: root, env: python_env(root)) do
      :ok -> ok(name, "#{humanize(name)} check passed")
      {:error, reason} -> error(name, "#{failure_message} (#{format_reason(reason)})")
    end
  end

  defp grpc_server_root(state) do
    candidates =
      [
        state.project_root,
        snakepit_app_root()
      ]
      |> Enum.reject(&is_nil/1)

    Enum.find(candidates, fn root ->
      File.exists?(Path.join(root, "priv/python/grpc_server.py"))
    end)
  end

  defp snakepit_app_root do
    case :code.priv_dir(:snakepit) do
      {:error, _} -> nil
      priv_dir -> priv_dir |> to_string() |> Path.dirname()
    end
  end

  defp python_env(root) do
    path_sep = path_separator()

    path =
      [
        Path.join(root, "priv/python"),
        snakepit_priv_python(),
        snakebridge_priv_python(),
        System.get_env("PYTHONPATH")
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()
      |> Enum.join(path_sep)

    [{"PYTHONPATH", path} | python_log_level_env()]
  end

  defp snakepit_priv_python do
    case :code.priv_dir(:snakepit) do
      {:error, _} -> nil
      priv_dir -> Path.join([to_string(priv_dir), "python"])
    end
  end

  defp snakebridge_priv_python do
    case :code.priv_dir(:snakebridge) do
      {:error, _} -> nil
      priv_dir -> Path.join([to_string(priv_dir), "python"])
    end
  end

  defp blank?(value), do: value in [nil, ""]

  defp python_log_level_env do
    level = Application.get_env(:snakepit, :log_level, :error)
    [{"SNAKEPIT_LOG_LEVEL", elixir_to_python_level(level)}]
  end

  defp elixir_to_python_level(:debug), do: "debug"
  defp elixir_to_python_level(:info), do: "info"
  defp elixir_to_python_level(:warning), do: "warning"
  defp elixir_to_python_level(:error), do: "error"
  defp elixir_to_python_level(:none), do: "none"
  defp elixir_to_python_level(_), do: "error"

  defp path_separator do
    case :os.type() do
      {:win32, _} -> ";"
      _ -> ":"
    end
  end

  defp configured_adapter_paths do
    case Snakepit.Config.get_pool_configs() do
      {:ok, pools} ->
        pools
        |> Enum.map(&extract_adapter_path(&1))
        |> Enum.reject(&is_nil/1)
        |> ensure_default_adapter()

      {:error, _} ->
        []
        |> ensure_default_adapter()
    end
  end

  defp extract_adapter_path(%{adapter_args: adapter_args}) do
    parse_adapter_from_args(adapter_args)
  end

  defp extract_adapter_path(_), do: nil

  defp parse_adapter_from_args(args) when is_list(args) do
    args
    |> Enum.reduce({nil, false}, fn arg, {found, expecting} ->
      cond do
        expecting ->
          {arg, false}

        is_binary(arg) and String.starts_with?(arg, "--adapter=") ->
          {String.replace_prefix(arg, "--adapter=", ""), false}

        arg == "--adapter" ->
          {found, true}

        true ->
          {found, false}
      end
    end)
    |> elem(0)
  end

  defp parse_adapter_from_args(_), do: nil

  defp ensure_default_adapter(adapters) do
    case adapters do
      [] ->
        default = parse_adapter_from_args(GRPCPython.script_args() || [])

        if default do
          [default]
        else
          []
        end

      _ ->
        Enum.uniq(adapters)
    end
  end

  defp check_adapter_imports(state, python_path, adapters) do
    root = grpc_server_root(state) || state.project_root
    script = Path.join(root, "priv/python/grpc_server.py")
    env = python_env(root)

    {ok_adapters, failed_adapters} =
      Enum.reduce(adapters, {[], []}, fn adapter, {oks, fails} ->
        args = [script, "--health-check", "--adapter", adapter]

        case state.runner.cmd(python_path, args, cd: root, env: env) do
          :ok -> {[adapter | oks], fails}
          {:error, reason} -> {oks, [{adapter, reason} | fails]}
        end
      end)

    case failed_adapters do
      [] ->
        ok(
          :adapter_imports,
          "Adapter import checks passed (#{length(ok_adapters)} adapters)"
        )

      _ ->
        failures =
          Enum.map_join(failed_adapters, ", ", fn {adapter, reason} ->
            "#{adapter} (#{format_reason(reason)})"
          end)

        error(
          :adapter_imports,
          "Adapter import checks failed: #{failures}"
        )
    end
  end

  defp default_adapter_args do
    GRPCPython.script_args()
  end

  defp ok(name, message), do: %{name: name, status: :ok, message: message}
  defp warning(name, message), do: %{name: name, status: :warning, message: message}
  defp error(name, message), do: %{name: name, status: :error, message: message}

  defp format_reason({:command_failed, command, status}),
    do: "#{command} exited with #{status}"

  defp format_reason(reason), do: inspect(reason)

  defp humanize(name) do
    name
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp python_path_for_check(%{python_path: nil, python_runtime: runtime}) do
    case PythonRuntime.missing_reason(runtime) do
      {:error, message} ->
        {:error, message}

      _ ->
        {:error,
         "Python not configured. Run mix snakepit.setup (or make bootstrap) or set SNAKEPIT_PYTHON=/path/to/python."}
    end
  end

  defp python_path_for_check(%{python_path: path}) do
    cond do
      not File.exists?(path) ->
        {:error,
         "Configured interpreter not found at #{path}. Run mix snakepit.setup (or make bootstrap)."}

      not executable?(path) ->
        {:error,
         "Interpreter at #{path} is not executable. Fix permissions or recreate the venv."}

      true ->
        {:ok, path}
    end
  end
end
