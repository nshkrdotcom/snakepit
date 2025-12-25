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

    grpc_port = opts[:grpc_port] || Application.get_env(:snakepit, :grpc_port, 50_051)

    %{
      project_root: project_root,
      python_path: python_path,
      runner: runner,
      require_python_313?: require_python_313?,
      grpc_port: grpc_port
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

  defp run_check(:venv, %{project_root: root}) do
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

  defp run_check(:venv_py313, %{project_root: root, require_python_313?: required?}) do
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

  defp run_check(:grpc_server, state) do
    case python_path_for_check(state) do
      {:ok, _} ->
        script = Path.join(state.project_root, "priv/python/grpc_server.py")

        if File.exists?(script) do
          args = [script, "--health-check"] ++ default_adapter_args()

          run_python(
            state,
            args,
            :grpc_server,
            "gRPC server health check failed. Regenerate stubs or reinstall deps."
          )
        else
          error(
            :grpc_server,
            "priv/python/grpc_server.py missing. Run mix snakepit.setup (or make bootstrap) to regenerate assets."
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

  defp run_check(:grpc_port, %{grpc_port: port}) do
    case :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        ok(:grpc_port, "Port #{port} available for the Elixir gRPC server")

      {:error, :eaddrinuse} ->
        error(
          :grpc_port,
          "Port #{port} is already in use. Stop the conflicting service or adjust :grpc_port."
        )

      {:error, reason} ->
        warning(:grpc_port, "Unable to verify port #{port}: #{inspect(reason)}")
    end
  end

  defp run_python(
         %{python_path: path, runner: runner, project_root: root},
         args,
         name,
         failure_message
       ) do
    case runner.cmd(path, args, cd: root, env: python_env(root)) do
      :ok -> ok(name, "#{humanize(name)} check passed")
      {:error, reason} -> error(name, "#{failure_message} (#{format_reason(reason)})")
    end
  end

  defp python_env(root) do
    python_path = Path.join(root, "priv/python")
    existing = System.get_env("PYTHONPATH")
    path_sep = path_separator()

    path =
      case existing do
        nil -> python_path
        "" -> python_path
        other -> python_path <> path_sep <> other
      end

    [{"PYTHONPATH", path}]
  end

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
    script = Path.join(state.project_root, "priv/python/grpc_server.py")
    env = python_env(state.project_root)

    {ok_adapters, failed_adapters} =
      Enum.reduce(adapters, {[], []}, fn adapter, {oks, fails} ->
        args = [script, "--health-check", "--adapter", adapter]

        case state.runner.cmd(python_path, args, cd: state.project_root, env: env) do
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

  defp python_path_for_check(%{python_path: nil}) do
    {:error,
     "Python not configured. Run mix snakepit.setup (or make bootstrap) or set SNAKEPIT_PYTHON=/path/to/python."}
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
