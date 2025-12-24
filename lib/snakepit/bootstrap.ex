defmodule Snakepit.Bootstrap do
  @moduledoc """
  Provisioning workflow for development and CI environments.

  It installs Mix dependencies, prepares the default Python virtual
  environments, regenerates gRPC stubs, and surfaces the interpreter path the
  application will use at runtime.
  """

  alias Snakepit.Bootstrap.Runner

  @requirements_path ["priv", "python", "requirements.txt"]
  @setup_script ["scripts", "setup_test_pythons.sh"]
  @grpc_script ["priv", "python", "generate_grpc.sh"]

  @doc """
  Execute the bootstrap workflow.

  Options:
    * `:project_root` - overrides the working directory (defaults to `File.cwd!/0`)
    * `:runner` - injects a custom runner, useful for tests
  """
  @spec run(Keyword.t()) :: :ok | {:error, term()}
  def run(opts \\ []) do
    # Prevent concurrent bootstrap runs - use fixed lock key
    lock = {__MODULE__, :bootstrap_lock}

    case :global.set_lock(lock, [node()], 0) do
      true ->
        run_with_lock(lock, fn -> do_run(opts) end)

      false ->
        Mix.shell().info("⚠️  Bootstrap already running, waiting...")
        :global.trans(lock, fn -> do_run(opts) end, [node()])
    end
  end

  defp run_with_lock(lock, fun) do
    try do
      fun.()
    after
      :global.del_lock(lock, [node()])
    end
  end

  defp do_run(opts) do
    state = build_state(opts)

    with :ok <- fetch_mix_deps(state),
         :ok <- ensure_primary_python(state),
         :ok <- run_script(state, @setup_script, :setup_pythons),
         :ok <- run_script(state, @grpc_script, :generate_grpc) do
      print_python_summary()
      Mix.shell().info("✅ Snakepit bootstrap complete")
      :ok
    else
      {:error, reason} = error ->
        Mix.shell().error("❌ Snakepit bootstrap failed: #{format_reason(reason)}")
        error
    end
  end

  defp build_state(opts) do
    project_root =
      opts[:project_root] ||
        Application.get_env(:snakepit, :bootstrap_project_root) ||
        File.cwd!()

    runner =
      opts[:runner] ||
        Application.get_env(:snakepit, :bootstrap_runner, Snakepit.Bootstrap.Runner.System)

    %{
      project_root: project_root,
      runner: runner
    }
  end

  defp fetch_mix_deps(%{runner: runner}) do
    Mix.shell().info("📦 mix deps.get")
    ensure_hex_started()

    case runner.mix("deps.get", []) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mix_failure, "deps.get", reason}}
    end
  end

  defp ensure_primary_python(%{project_root: root, runner: runner}) do
    requirements = Path.join([root | @requirements_path])

    unless File.exists?(requirements) do
      return_missing(:requirements, requirements)
    else
      with :ok <- create_primary_venv(root, runner),
           :ok <- install_requirements(root, requirements, runner) do
        :ok
      end
    end
  end

  defp create_primary_venv(root, runner) do
    venv_dir = Path.join(root, ".venv")

    if File.dir?(venv_dir) do
      :ok
    else
      python = discover_python()

      unless python do
        {:error, :python_not_found}
      else
        Mix.shell().info("🐍 Creating .venv with #{python}")

        case runner.cmd(python, ["-m", "venv", ".venv"], cd: root) do
          :ok ->
            Mix.shell().info("✅ .venv created successfully")
            :ok

          error ->
            error
        end
      end
    end
  end

  defp install_requirements(root, requirements, runner) do
    Mix.shell().info("📦 Installing Python requirements")
    pip = Path.join([root, ".venv", "bin", "pip"])
    runner.cmd(pip, ["install", "-r", requirements], cd: root)
  end

  defp run_script(%{project_root: root, runner: runner}, parts, step) do
    script = Path.join([root | parts])

    unless File.exists?(script) do
      return_missing(step, script)
    else
      Mix.shell().info("▶️  #{describe_step(step)}")
      runner.cmd(script, [], cd: root)
    end
  end

  defp describe_step(:setup_pythons), do: "scripts/setup_test_pythons.sh"
  defp describe_step(:generate_grpc), do: "priv/python/generate_grpc.sh"

  defp print_python_summary do
    python = Snakepit.Adapters.GRPCPython.executable_path()

    if python do
      Mix.shell().info("🐍 Detected Python interpreter: #{python}")
    else
      Mix.shell().info("🐍 No interpreter detected (set SNAKEPIT_PYTHON=/path/to/python)")
    end

    Mix.shell().info("ℹ️  Override via SNAKEPIT_PYTHON=/path/to/python")
  end

  defp discover_python do
    System.find_executable("python3") || System.find_executable("python")
  end

  defp ensure_hex_started do
    Mix.ensure_application!(:hex)
  rescue
    _ -> :ok
  end

  defp return_missing(kind, path), do: {:error, {:missing, kind, path}}

  defp format_reason({:mix_failure, task, reason}),
    do: "mix #{task} failed: #{inspect(reason)}"

  defp format_reason({:missing, kind, path}),
    do: "missing #{kind} at #{path}"

  defp format_reason(:python_not_found),
    do: "python3/python not found in PATH"

  defp format_reason({:command_failed, command, status}),
    do: "#{command} exited with status #{status}"

  defp format_reason(reason), do: inspect(reason)

  defmodule Runner do
    @moduledoc """
    Behaviour for executing bootstrap steps. Allows tests to inject fakes.
    """

    @callback mix(task :: String.t(), args :: [String.t()]) :: :ok | {:error, term()}
    @callback cmd(command :: String.t(), args :: [String.t()], keyword()) ::
                :ok | {:error, term()}

    defmodule System do
      @moduledoc false
      @behaviour Snakepit.Bootstrap.Runner

      # Alias the Elixir System module to avoid name collision
      alias Elixir.System, as: ErlangSystem

      @impl true
      def mix(task, args) do
        try do
          Mix.Task.run(task, args)
          :ok
        catch
          kind, reason ->
            {:error, {kind, reason}}
        end
      end

      @impl true
      def cmd(command, args, opts) do
        opts = Keyword.put_new(opts, :stderr_to_stdout, true)

        # For shell scripts, call through bash to handle shebang properly
        {actual_command, actual_args} =
          if String.ends_with?(command, ".sh") do
            {"bash", [command | args]}
          else
            {command, args}
          end

        # Use ErlangSystem to avoid recursive call!
        case ErlangSystem.cmd(actual_command, actual_args, opts) do
          {output, 0} ->
            if String.trim(output) != "" do
              IO.write(output)
            end

            :ok

          {output, status} ->
            if String.trim(output) != "" do
              IO.write(output)
            end

            {:error, {:command_failed, command, status}}
        end
      end
    end
  end
end
