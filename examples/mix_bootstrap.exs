defmodule Snakepit.Examples.Bootstrap do
  @moduledoc false

  require Logger

  @spec ensure_mix!([term()]) :: :ok
  def ensure_mix!(deps) when is_list(deps) do
    mix_started =
      case Application.ensure_all_started(:mix) do
        {:ok, _apps} -> true
        {:error, {:already_started, :mix}} -> true
        _ -> false
      end

    project_loaded? =
      mix_started and
        Code.ensure_loaded?(Mix.Project) and
        function_exported?(Mix.Project, :get, 0) and
        Mix.Project.get() != nil

    unless project_loaded? do
      Mix.install(deps)
    end

    Application.ensure_all_started(:telemetry)

    maybe_apply_snakepit_log_level()
    configure_logger_from_snakepit()

    :ok
  end

  defp maybe_apply_snakepit_log_level do
    case System.get_env("SNAKEPIT_LOG_LEVEL") do
      nil ->
        :ok

      value ->
        case normalize_log_level(value) do
          {:ok, level} -> Application.put_env(:snakepit, :log_level, level)
          :error -> :ok
        end
    end
  end

  defp normalize_log_level(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "debug" -> {:ok, :debug}
      "info" -> {:ok, :info}
      "warning" -> {:ok, :warning}
      "warn" -> {:ok, :warning}
      "error" -> {:ok, :error}
      "none" -> {:ok, :none}
      _ -> :error
    end
  end

  defp configure_logger_from_snakepit do
    level =
      Application.get_env(:snakepit, :log_level, :error)
      |> map_snakepit_level()

    Logger.configure(level: level)
  end

  defp map_snakepit_level(:none), do: :error
  defp map_snakepit_level(:warning), do: :warning
  defp map_snakepit_level(:error), do: :error
  defp map_snakepit_level(:debug), do: :debug
  defp map_snakepit_level(_), do: :info

  @spec await_pool_ready!(timeout()) :: :ok
  def await_pool_ready!(timeout \\ 15_000) do
    case Process.whereis(Snakepit.Pool) do
      nil ->
        :ok

      _pid ->
        case Snakepit.Pool.await_ready(Snakepit.Pool, timeout) do
          :ok -> :ok
          {:error, reason} -> raise "Pool did not initialize: #{inspect(reason)}"
        end
    end
  end

  @spec run_example((-> any()), Keyword.t()) :: any()
  def run_example(fun, opts \\ []) when is_function(fun, 0) do
    await_pool = Keyword.get(opts, :await_pool, pooling_enabled?())
    await_timeout = Keyword.get(opts, :await_timeout, Keyword.get(opts, :timeout, 15_000))

    run_opts =
      opts
      |> Keyword.put(:await_pool, false)
      |> Keyword.put_new(:halt, true)

    Snakepit.run_as_script(
      fn ->
        if await_pool do
          await_pool_ready!(await_timeout)
        end

        fun.()
      end,
      run_opts
    )
  end

  defp pooling_enabled? do
    Application.get_env(:snakepit, :pooling_enabled, false)
  end

  @spec ensure_grpc_port!() :: :ok
  def ensure_grpc_port! do
    port = Application.get_env(:snakepit, :grpc_port, 50_051)

    if port_available?(port) do
      :ok
    else
      available = find_available_port()
      Application.put_env(:snakepit, :grpc_port, available)
      IO.puts("ℹ️  grpc_port #{port} in use; using #{available} instead")
      :ok
    end
  end

  defp port_available?(port) do
    case :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, :eaddrinuse} ->
        false

      {:error, _reason} ->
        false
    end
  end

  defp find_available_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_ip, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end

  @spec format_error(term()) :: String.t()
  def format_error(%{__struct__: mod, message: message} = error) when is_binary(message) do
    type = mod |> Module.split() |> List.last()
    python_type = Map.get(error, :python_type)

    label =
      if is_binary(python_type) and python_type != "" and python_type != type do
        "#{type}(#{python_type})"
      else
        type
      end

    "#{label}: #{message}"
  end

  def format_error(reason), do: inspect(reason)
end
