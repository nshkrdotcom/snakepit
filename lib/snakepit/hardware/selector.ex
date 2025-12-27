defmodule Snakepit.Hardware.Selector do
  @moduledoc """
  Device selection logic for hardware abstraction.

  Provides intelligent device selection based on availability, preferences,
  and fallback strategies.
  """

  alias Snakepit.Hardware.Detector

  @type device ::
          :cpu
          | :cuda
          | :mps
          | :rocm
          | {:cuda, non_neg_integer()}
          | {:rocm, non_neg_integer()}

  @type device_preference :: :auto | :cpu | :cuda | :mps | :rocm | {:cuda, non_neg_integer()}

  @doc """
  Selects a device based on preference.

  ## Options

  - `:auto` - Automatically select the best available accelerator
  - `:cpu` - Select CPU (always available)
  - `:cuda` - Select CUDA (fails if not available)
  - `:mps` - Select MPS (fails if not available or not on macOS)
  - `:rocm` - Select ROCm (fails if not available)
  - `{:cuda, device_id}` - Select specific CUDA device

  ## Returns

  - `{:ok, device}` on success
  - `{:error, :device_not_available}` if requested device is unavailable
  """
  @spec select(device_preference()) :: {:ok, device()} | {:error, :device_not_available}
  def select(:auto) do
    info = Detector.detect()

    device =
      cond do
        info.cuda != nil and info.cuda.devices != [] ->
          {:cuda, 0}

        info.mps != nil and info.mps.available ->
          :mps

        info.rocm != nil and info.rocm.devices != [] ->
          {:rocm, 0}

        true ->
          :cpu
      end

    {:ok, device}
  end

  def select(:cpu) do
    {:ok, :cpu}
  end

  def select(:cuda) do
    info = Detector.detect()

    case info.cuda do
      %{devices: [_ | _]} ->
        {:ok, {:cuda, 0}}

      _ ->
        {:error, :device_not_available}
    end
  end

  def select({:cuda, device_id}) when is_integer(device_id) do
    info = Detector.detect()

    case info.cuda do
      %{devices: devices} when is_list(devices) ->
        if Enum.any?(devices, &(&1.id == device_id)) do
          {:ok, {:cuda, device_id}}
        else
          {:error, :device_not_available}
        end

      _ ->
        {:error, :device_not_available}
    end
  end

  def select(:mps) do
    info = Detector.detect()

    case info.mps do
      %{available: true} ->
        {:ok, :mps}

      _ ->
        {:error, :device_not_available}
    end
  end

  def select(:rocm) do
    info = Detector.detect()

    case info.rocm do
      %{devices: [_ | _]} ->
        {:ok, {:rocm, 0}}

      _ ->
        {:error, :device_not_available}
    end
  end

  def select({:rocm, device_id}) when is_integer(device_id) do
    info = Detector.detect()

    case info.rocm do
      %{devices: devices} when is_list(devices) ->
        if Enum.any?(devices, &(&1.id == device_id)) do
          {:ok, {:rocm, device_id}}
        else
          {:error, :device_not_available}
        end

      _ ->
        {:error, :device_not_available}
    end
  end

  def select(_), do: {:error, :device_not_available}

  @doc """
  Selects the first available device from a preference list.

  Tries each device in order until one is available, returning that device.
  If no devices are available, returns `{:error, :no_device}`.

  ## Examples

      iex> Hardware.Selector.select_with_fallback([:cuda, :mps, :cpu])
      {:ok, :cpu}  # if CUDA and MPS unavailable
  """
  @spec select_with_fallback([device_preference()]) ::
          {:ok, device()} | {:error, :no_device}
  def select_with_fallback([]) do
    {:error, :no_device}
  end

  def select_with_fallback([preference | rest]) do
    case select(preference) do
      {:ok, device} -> {:ok, device}
      {:error, _} -> select_with_fallback(rest)
    end
  end

  @doc """
  Returns information about a selected device.

  Returns a map with device details useful for logging and telemetry.
  """
  @spec device_info(device()) :: map()
  def device_info(:cpu) do
    info = Detector.detect()

    %{
      type: :cpu,
      name: info.cpu.model,
      cores: info.cpu.cores,
      threads: info.cpu.threads,
      memory_mb: info.cpu.memory_total_mb
    }
  end

  def device_info({:cuda, device_id}) do
    info = Detector.detect()

    case info.cuda do
      %{devices: devices, version: version} ->
        device = Enum.find(devices, &(&1.id == device_id))

        if device do
          %{
            type: :cuda,
            device_id: device_id,
            name: device.name,
            memory_total_mb: device.memory_total_mb,
            memory_free_mb: device.memory_free_mb,
            cuda_version: version,
            compute_capability: device.compute_capability
          }
        else
          %{type: :cuda, device_id: device_id, error: :device_not_found}
        end

      _ ->
        %{type: :cuda, device_id: device_id, error: :cuda_not_available}
    end
  end

  def device_info(:cuda) do
    device_info({:cuda, 0})
  end

  def device_info(:mps) do
    info = Detector.detect()

    case info.mps do
      %{available: true} = mps ->
        %{
          type: :mps,
          name: mps.device_name,
          memory_mb: mps.memory_total_mb
        }

      _ ->
        %{type: :mps, error: :mps_not_available}
    end
  end

  def device_info({:rocm, device_id}) do
    info = Detector.detect()

    case info.rocm do
      %{devices: devices, version: version} ->
        device = Enum.find(devices, &(&1.id == device_id))

        if device do
          %{
            type: :rocm,
            device_id: device_id,
            name: device.name,
            memory_total_mb: device.memory_total_mb,
            rocm_version: version
          }
        else
          %{type: :rocm, device_id: device_id, error: :device_not_found}
        end

      _ ->
        %{type: :rocm, device_id: device_id, error: :rocm_not_available}
    end
  end

  def device_info(:rocm) do
    device_info({:rocm, 0})
  end
end
