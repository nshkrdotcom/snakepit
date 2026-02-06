defmodule Snakepit.PythonPackages do
  @moduledoc """
  Package installation and inspection for Snakepit-managed Python runtimes.

  Requires [uv](https://docs.astral.sh/uv/) for package management. Install with:

      curl -LsSf https://astral.sh/uv/install.sh | sh

  ## Examples

      Snakepit.PythonPackages.ensure!({:list, ["numpy~=1.26", "scipy~=1.11"]})

      {:ok, :all_installed} =
        Snakepit.PythonPackages.check_installed(["numpy~=1.26", "scipy~=1.11"])

      {:ok, metadata} = Snakepit.PythonPackages.lock_metadata(["numpy~=1.26"])

      Snakepit.PythonPackages.ensure!({:file, "requirements.txt"}, upgrade: true)
  """

  alias Snakepit.PackageError
  alias Snakepit.PythonRuntime

  @type requirement :: String.t()
  @type requirements_spec ::
          {:list, [requirement()]}
          | {:file, Path.t()}

  @default_env %{
    "PYTHONNOUSERSITE" => "1",
    "PIP_DISABLE_PIP_VERSION_CHECK" => "1",
    "PIP_NO_INPUT" => "1",
    "PIP_NO_WARN_SCRIPT_LOCATION" => "1",
    "UV_NO_PROGRESS" => "1",
    "PYTHONDONTWRITEBYTECODE" => "1"
  }

  @default_timeout 300_000

  @doc """
  Ensure all packages in the requirements spec are installed and satisfy version constraints.

  Uses `uv pip install --dry-run` to check if packages need to be installed or upgraded,
  then installs any missing or outdated packages.

  Options:
    * `:upgrade` - upgrade matching packages
    * `:quiet` - suppress installer output
    * `:timeout` - install timeout in ms
  """
  @spec ensure!(requirements_spec(), keyword()) :: :ok | no_return()
  def ensure!(spec, opts \\ []) do
    requirements = normalize_spec!(spec)

    case check_installed(requirements, opts) do
      {:ok, :all_installed} -> :ok
      {:ok, {:missing, missing}} -> install!(missing, opts)
    end
  end

  @doc """
  Check which packages are installed and satisfy their version constraints.

  Uses `uv pip install --dry-run` for accurate PEP-440 version checking.
  Returns `{:ok, :all_installed}` when every requirement is satisfied, or
  `{:ok, {:missing, requirements}}` when any are missing or have version mismatches.
  """
  @spec check_installed([requirement()], keyword()) ::
          {:ok, :all_installed} | {:ok, {:missing, [requirement()]}}
  def check_installed(requirements, opts \\ []) do
    requirements = normalize_list(requirements)
    validate_requirements!(requirements)

    do_check_installed(requirements, opts)
  end

  @doc """
  Return package metadata for lockfiles.

  The result maps package name to `%{version: version, hash: hash}` entries.
  """
  @spec lock_metadata([requirement()], keyword()) :: {:ok, map()} | {:error, term()}
  def lock_metadata(requirements, opts \\ []) do
    requirements = normalize_list(requirements)
    validate_requirements!(requirements)

    if requirements == [] do
      {:ok, %{}}
    else
      python = package_python!(opts)

      case freeze(python, opts) do
        {:ok, output} -> {:ok, build_metadata(requirements, output)}
        {:error, %PackageError{} = error} -> {:error, error}
      end
    end
  end

  @doc """
  Install the given package requirements using uv.

  Prefer `ensure!/2` unless you already know which requirements are missing.
  """
  @spec install!([requirement()], keyword()) :: :ok | no_return()
  def install!(requirements, opts \\ []) do
    requirements = normalize_list(requirements)
    validate_requirements!(requirements)

    if requirements == [] do
      :ok
    else
      python = package_python!(opts)

      args =
        ["pip", "install", "--python", python] ++
          build_install_args(opts) ++
          requirements

      {output, status} = run_cmd(uv_path!(), args, opts)

      if status == 0 do
        :ok
      else
        raise PackageError,
          type: :install_failed,
          packages: requirements,
          message: "uv install failed with exit code #{status}",
          output: output,
          suggestion: "Check package names and network connectivity."
      end
    end
  end

  defmodule Runner do
    @moduledoc false
    @callback cmd(String.t(), [String.t()], keyword()) :: {String.t(), non_neg_integer()}
  end

  defmodule Runner.System do
    @moduledoc false
    @behaviour Runner

    @impl true
    def cmd(command, args, opts) do
      {timeout, opts} = Keyword.pop(opts, :timeout)

      run = fn -> System.cmd(command, args, opts) end

      if is_integer(timeout) do
        case run_with_timeout(run, timeout) do
          {:ok, result} ->
            result

          :timeout ->
            {"Command timed out after #{timeout}ms", 124}

          {:error, reason} ->
            {"#{format_cmd_error(reason)}", 127}
        end
      else
        run.()
      end
    rescue
      error in ErlangError ->
        {"#{Exception.message(error)}", 127}
    end

    defp run_with_timeout(fun, timeout_ms) when is_function(fun, 0) and is_integer(timeout_ms) do
      caller = self()
      result_ref = make_ref()

      {pid, monitor_ref} =
        spawn_monitor(fn ->
          result =
            try do
              {:ok, fun.()}
            rescue
              exception ->
                {:error, {exception, __STACKTRACE__}}
            catch
              kind, reason ->
                {:error, {kind, reason}}
            end

          send(caller, {result_ref, result})
        end)

      receive do
        {^result_ref, {:ok, result}} ->
          Process.demonitor(monitor_ref, [:flush])
          {:ok, result}

        {^result_ref, {:error, reason}} ->
          Process.demonitor(monitor_ref, [:flush])
          {:error, reason}

        {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
          {:error, reason}
      after
        timeout_ms ->
          Process.exit(pid, :kill)
          Process.demonitor(monitor_ref, [:flush])
          :timeout
      end
    end

    defp format_cmd_error({exception, _stacktrace}) when is_exception(exception) do
      Exception.message(exception)
    end

    defp format_cmd_error({kind, reason}) do
      "#{kind}: #{inspect(reason)}"
    end

    defp format_cmd_error(reason), do: inspect(reason)
  end

  defp config do
    raw =
      :snakepit
      |> Application.get_env(:python_packages, [])
      |> normalize_config_input()

    runtime_env = normalize_env_input(PythonRuntime.config().extra_env)
    env_override = normalize_env_input(Map.get(raw, :env, %{}))

    %{
      timeout: Map.get(raw, :timeout, @default_timeout),
      env: @default_env |> Map.merge(runtime_env) |> Map.merge(env_override),
      runner: Map.get(raw, :runner, Runner.System),
      env_dir: Map.get(raw, :env_dir)
    }
  end

  defp normalize_spec!({:list, requirements}) when is_list(requirements) do
    normalize_list(requirements)
  end

  defp normalize_spec!({:file, path}) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> normalize_list()

      {:error, reason} ->
        raise PackageError,
          type: :invalid_requirement,
          packages: [path],
          message: "Could not read requirements file: #{inspect(reason)}",
          suggestion: "Check the file path and permissions."
    end
  end

  defp normalize_spec!(spec) do
    raise PackageError,
      type: :invalid_requirement,
      packages: [inspect(spec)],
      message: "Unsupported requirements spec",
      suggestion: "Use {:list, requirements} or {:file, path}."
  end

  defp normalize_list(nil), do: []

  defp normalize_list(requirements) when is_list(requirements) do
    requirements
    |> Enum.map(&normalize_requirement!/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_list(other) do
    raise PackageError,
      type: :invalid_requirement,
      packages: [inspect(other)],
      message: "Requirements must be a list of strings",
      suggestion: "Provide a list like [\"numpy~=1.26\"]."
  end

  defp normalize_requirement!(requirement) when is_binary(requirement) do
    requirement
    |> String.split("#", parts: 2)
    |> hd()
    |> String.trim()
  end

  defp normalize_requirement!(requirement) do
    raise PackageError,
      type: :invalid_requirement,
      packages: [inspect(requirement)],
      message: "Requirement must be a string",
      suggestion: "Use PEP-440 requirement strings."
  end

  defp validate_requirements!(requirements) do
    invalid =
      requirements
      |> Enum.reject(&is_binary/1)

    if invalid != [] do
      raise PackageError,
        type: :invalid_requirement,
        packages: invalid,
        message: "Requirements must be strings",
        suggestion: "Use PEP-440 requirement strings."
    end
  end

  defp do_check_installed([], _opts), do: {:ok, :all_installed}

  defp do_check_installed(requirements, opts) do
    python = package_python!(opts)

    missing =
      requirements
      |> Enum.reduce([], fn requirement, acc ->
        if requirement_satisfied?(python, requirement, opts) do
          acc
        else
          [requirement | acc]
        end
      end)
      |> Enum.reverse()

    case missing do
      [] -> {:ok, :all_installed}
      _ -> {:ok, {:missing, missing}}
    end
  end

  # Extracts the package name from a requirement string.
  # Used for building metadata maps.
  defp requirement_name!(requirement) do
    name =
      requirement
      |> String.split(";", parts: 2)
      |> hd()
      |> String.split(~r/\s*@\s*/, parts: 2)
      |> hd()
      |> String.trim()
      |> String.split("[", parts: 2)
      |> hd()
      |> String.split(~r/[<>=!~]/, parts: 2)
      |> hd()
      |> String.trim()

    if name == "" do
      raise PackageError,
        type: :invalid_requirement,
        packages: [requirement],
        message: "Could not derive package name from requirement",
        suggestion: "Use PEP-440 requirement strings."
    end

    name
  end

  defp base_python! do
    case PythonRuntime.resolve_executable() do
      {:ok, python, _meta} ->
        python

      {:error, reason} ->
        raise PackageError,
          type: :install_failed,
          packages: [],
          message: "Python runtime unavailable: #{inspect(reason)}",
          suggestion: "Run mix snakepit.setup or set SNAKEPIT_PYTHON."
    end
  end

  defp package_python!(opts) do
    base = base_python!()

    case env_dir(config()) do
      nil ->
        base

      env_dir ->
        ensure_venv!(base, env_dir, opts)
        venv_python!(env_dir)
    end
  end

  # Checks if a requirement (with version spec) is satisfied by installed packages.
  # Uses `uv pip install --dry-run` which is fast and provides accurate PEP-440
  # version checking without actually installing anything.
  defp requirement_satisfied?(python, requirement, opts) do
    # Editable installs should always be reinstalled
    if editable_requirement?(requirement) do
      false
    else
      args = ["pip", "install", "--dry-run", "--python", python, requirement]
      {output, status} = run_cmd(uv_path!(), args, opts)

      # uv returns 0 on success. Check output to see if it would install anything.
      # "Would install" or "Would upgrade" or "Would downgrade" = not satisfied
      # "Audited" with no changes = satisfied
      status == 0 and not would_install?(output)
    end
  end

  defp editable_requirement?(requirement) do
    trimmed = String.trim(requirement)
    String.starts_with?(trimmed, "-e ") or String.starts_with?(trimmed, "--editable")
  end

  defp would_install?(output) do
    String.contains?(output, "Would install") or
      String.contains?(output, "Would upgrade") or
      String.contains?(output, "Would downgrade")
  end

  defp freeze(python, opts) do
    {output, status} =
      run_cmd(
        uv_path!(),
        ["pip", "freeze", "--python", python],
        opts
      )

    if status == 0 do
      {:ok, output}
    else
      {:error,
       %PackageError{
         type: :install_failed,
         packages: [],
         message: "uv freeze failed with exit code #{status}",
         output: output,
         suggestion: "Verify the Python environment is accessible."
       }}
    end
  end

  defp build_metadata(requirements, output) do
    versions = parse_freeze_output(output)

    Enum.reduce(requirements, %{}, fn requirement, acc ->
      name = requirement_name!(requirement)
      version = Map.get(versions, String.downcase(name))
      Map.put(acc, name, %{version: version, hash: nil})
    end)
  end

  defp parse_freeze_output(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "==", parts: 2) do
        [name, version] ->
          Map.put(acc, String.downcase(String.trim(name)), String.trim(version))

        _ ->
          acc
      end
    end)
  end

  defp build_install_args(opts) do
    args = []
    args = if Keyword.get(opts, :upgrade, false), do: args ++ ["--upgrade"], else: args
    args = if Keyword.get(opts, :quiet, false), do: args ++ ["--quiet"], else: args
    args
  end

  defp run_cmd(command, args, opts) do
    runner = opts[:runner] || config().runner
    runner.cmd(command, args, cmd_opts(opts))
  end

  defp cmd_opts(opts) do
    config = config()
    timeout = Keyword.get(opts, :timeout, config.timeout)

    [
      env: Map.to_list(config.env),
      stderr_to_stdout: true,
      timeout: timeout
    ]
  end

  defp env_dir(config) do
    case Map.get(config, :env_dir) do
      false -> nil
      nil -> default_env_dir()
      value -> Path.expand(value, File.cwd!())
    end
  end

  defp default_env_dir do
    runtime_dir = PythonRuntime.config().runtime_dir || "priv/snakepit/python"
    Path.expand(Path.join(runtime_dir, "venv"), File.cwd!())
  end

  defp ensure_venv!(base_python, env_dir, opts) do
    if venv_python_paths(env_dir) |> Enum.any?(&File.exists?/1) do
      :ok
    else
      File.mkdir_p!(env_dir)
      # Use uv to create the venv for consistency
      {output, status} = run_cmd(uv_path!(), ["venv", "--python", base_python, env_dir], opts)

      if status == 0 do
        :ok
      else
        raise PackageError,
          type: :install_failed,
          packages: [],
          message: "Failed to create virtual environment in #{env_dir}",
          output: output,
          suggestion: "Ensure uv is installed and the directory is writable."
      end
    end
  end

  defp venv_python!(env_dir) do
    case Enum.find(venv_python_paths(env_dir), &File.exists?/1) do
      nil ->
        raise PackageError,
          type: :install_failed,
          packages: [],
          message: "Virtual environment missing Python executable in #{env_dir}",
          suggestion: "Remove the directory and retry setup."

      python ->
        python
    end
  end

  defp venv_python_paths(env_dir) do
    [
      Path.join([env_dir, "bin", "python3"]),
      Path.join([env_dir, "bin", "python"]),
      Path.join([env_dir, "Scripts", "python.exe"]),
      Path.join([env_dir, "Scripts", "python"])
    ]
  end

  defp uv_path do
    PythonRuntime.config().uv_path || System.find_executable("uv")
  end

  defp uv_path! do
    case uv_path() do
      nil ->
        raise PackageError,
          type: :uv_not_found,
          packages: [],
          message: "uv is required but not found",
          suggestion:
            "Install uv: curl -LsSf https://astral.sh/uv/install.sh | sh\n" <>
              "Or set config :snakepit, :python, uv_path: \"/path/to/uv\""

      path ->
        path
    end
  end

  defp normalize_config_input(nil), do: %{}
  defp normalize_config_input(%{} = map), do: map
  defp normalize_config_input(list) when is_list(list), do: Map.new(list)
  defp normalize_config_input(_), do: %{}

  defp normalize_env_input(nil), do: %{}
  defp normalize_env_input(%{} = map), do: map
  defp normalize_env_input(list) when is_list(list), do: Map.new(list)
  defp normalize_env_input(_), do: %{}
end
