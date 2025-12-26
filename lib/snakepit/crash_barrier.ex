defmodule Snakepit.CrashBarrier do
  @moduledoc """
  Crash barrier policy for worker failures.

  Classifies worker crashes, taints unstable workers, and determines retry eligibility.
  """

  alias Snakepit.Error
  alias Snakepit.Worker.TaintRegistry

  @default_config %{
    enabled: false,
    retry: :idempotent,
    max_restarts: 1,
    taint_duration_ms: 60_000,
    backoff_ms: [50, 100, 200],
    mark_on: [:segfault, :oom, :gpu],
    taint_on_exit_codes: [],
    taint_on_error_types: [],
    taint_device_on_cuda_fatal: true
  }

  @segfault_codes [139]
  @abort_codes [134]
  @oom_codes [137]

  def config(pool_config \\ %{}) do
    global =
      :snakepit
      |> Application.get_env(:crash_barrier, [])
      |> Map.new()

    pool_override =
      pool_config
      |> Map.get(:crash_barrier, %{})
      |> Map.new()

    @default_config
    |> Map.merge(global)
    |> Map.merge(pool_override)
    |> normalize_config()
  end

  def enabled?(config), do: config.enabled == true

  def idempotent?(args) when is_map(args) do
    Map.get(args, :idempotent) || Map.get(args, "idempotent") || false
  end

  def idempotent?(_), do: false

  def crash_info({:error, {:worker_exit, reason}}, config) do
    classify_reason(reason, config)
  end

  def crash_info({:error, {:worker_crash, info}}, _config) do
    {:ok, info}
  end

  def crash_info(_result, _config), do: :error

  def retry_allowed?(config, idempotent, attempt) do
    max_retries = retry_limit(config)

    cond do
      attempt >= max_retries -> false
      config.retry == :always -> true
      config.retry == :idempotent -> idempotent
      true -> false
    end
  end

  def retry_backoff(config, attempt) do
    backoffs = List.wrap(config.backoff_ms)

    case Enum.at(backoffs, attempt - 1) do
      nil -> List.last(backoffs) || 0
      value -> value
    end
  end

  def taint_worker(pool_name, worker_id, info, config) do
    TaintRegistry.taint_worker(worker_id,
      duration_ms: config.taint_duration_ms,
      reason: info.reason,
      exit_code: info.exit_code,
      device: info.device
    )

    emit_worker_tainted(pool_name, worker_id, info, config)
    :ok
  end

  def worker_tainted?(worker_id), do: TaintRegistry.worker_tainted?(worker_id)

  def maybe_emit_restart(pool_name, worker_id) do
    case TaintRegistry.consume_restart(worker_id) do
      {:ok, info} ->
        :telemetry.execute(
          [:snakepit, :worker, :restarted],
          %{},
          %{
            worker_id: worker_id,
            pool: pool_name,
            reason: info.reason,
            exit_code: info.exit_code,
            device: info.device
          }
        )

      :error ->
        :ok
    end
  end

  def normalize_crash_error({:error, {:worker_exit, reason}}, info) do
    {:error,
     Error.worker_error("Python worker crashed", %{
       type: :worker_crash,
       reason: reason,
       exit_code: info.exit_code,
       classification: info.classification
     })}
  end

  def normalize_crash_error(result, _info), do: result

  defp classify_reason(reason, config) do
    exit_code = exit_code_from_reason(reason)
    reason_string = inspect(reason)
    error_type = error_type_from_reason(reason_string, config)

    classification =
      cond do
        exit_code in @segfault_codes -> :segfault
        exit_code in @abort_codes -> :abort
        exit_code in @oom_codes -> :oom
        error_type == :gpu -> :gpu
        true -> :unknown
      end

    if should_taint?(config, exit_code, error_type, classification) do
      {:ok,
       %{
         reason: reason,
         exit_code: exit_code,
         classification: classification,
         device: device_from_reason(reason)
       }}
    else
      :error
    end
  end

  defp should_taint?(config, exit_code, error_type, classification) do
    mark_on = normalize_mark_on(config.mark_on)

    cond do
      exit_code in taint_exit_codes(config, mark_on) ->
        true

      error_type == :gpu and :gpu in mark_on ->
        true

      classification in mark_on ->
        true

      true ->
        false
    end
  end

  defp taint_exit_codes(config, mark_on) do
    config.taint_on_exit_codes
    |> List.wrap()
    |> Kernel.++(exit_codes_for(mark_on))
    |> Enum.uniq()
  end

  defp exit_codes_for(mark_on) do
    []
    |> maybe_append(:segfault in mark_on, @segfault_codes)
    |> maybe_append(:abort in mark_on, @abort_codes)
    |> maybe_append(:oom in mark_on, @oom_codes)
  end

  defp maybe_append(list, true, values), do: list ++ values
  defp maybe_append(list, false, _values), do: list

  defp normalize_mark_on(mark_on) do
    mark_on
    |> List.wrap()
    |> Enum.map(fn
      value when is_atom(value) -> value
      value when is_binary(value) -> normalize_mark_atom(value)
      _ -> :unknown
    end)
  end

  defp normalize_mark_atom(value) do
    case String.downcase(value) do
      "segfault" -> :segfault
      "oom" -> :oom
      "gpu" -> :gpu
      "abort" -> :abort
      _ -> :unknown
    end
  end

  defp error_type_from_reason(reason_string, config) do
    reason_string = String.downcase(reason_string)
    configured = config.taint_on_error_types |> List.wrap() |> Enum.map(&String.downcase/1)

    cond do
      Enum.any?(configured, &String.contains?(reason_string, &1)) -> :gpu
      String.contains?(reason_string, "cuda") -> :gpu
      String.contains?(reason_string, "gpu") -> :gpu
      true -> :unknown
    end
  end

  defp device_from_reason(reason) do
    if String.contains?(inspect(reason), "CUDA") do
      :cuda
    else
      nil
    end
  end

  defp exit_code_from_reason({:grpc_server_exited, status}) when is_integer(status), do: status
  defp exit_code_from_reason({:exit_status, status}) when is_integer(status), do: status
  defp exit_code_from_reason({:external_process_died, {:exit_status, status}}), do: status
  defp exit_code_from_reason({:shutdown, {:grpc_server_exited, status}}), do: status
  defp exit_code_from_reason(_), do: nil

  defp retry_limit(config) do
    Map.get(config, :max_restarts) || Map.get(config, :max_retries) || 1
  end

  defp normalize_config(config) do
    config
    |> Map.update(:retry, :idempotent, fn
      true -> :always
      false -> :never
      value -> value
    end)
    |> Map.merge(retry_from_legacy(config))
  end

  defp retry_from_legacy(config) do
    case Map.fetch(config, :retry_idempotent) do
      {:ok, true} -> %{retry: :idempotent}
      {:ok, false} -> %{retry: :never}
      :error -> %{}
    end
  end

  defp emit_worker_tainted(pool_name, worker_id, info, config) do
    :telemetry.execute(
      [:snakepit, :worker, :crash],
      %{},
      %{
        worker_id: worker_id,
        pool: pool_name,
        reason: info.reason,
        exit_code: info.exit_code,
        device: info.device
      }
    )

    :telemetry.execute(
      [:snakepit, :worker, :tainted],
      %{duration_ms: config.taint_duration_ms},
      %{
        worker_id: worker_id,
        pool: pool_name,
        reason: info.reason,
        exit_code: info.exit_code,
        device: info.device
      }
    )
  end
end
