defmodule Snakepit.GRPC.EndpointRegistry do
  @moduledoc false

  alias Snakepit.Config
  alias Snakepit.Logger, as: SLog

  @endpoint_key {__MODULE__, :endpoint_module}
  @log_category :grpc

  @spec endpoint_module() :: module()
  def endpoint_module do
    case :persistent_term.get(@endpoint_key, nil) do
      nil ->
        endpoint = build_endpoint_module()
        :persistent_term.put(@endpoint_key, endpoint)
        endpoint

      endpoint ->
        endpoint
    end
  end

  defp build_endpoint_module do
    identifier = endpoint_identifier()
    suffix = endpoint_suffix(identifier)
    module_name = Module.concat([Snakepit, GRPC, Endpoint, suffix])

    if Code.ensure_loaded?(module_name) do
      module_name
    else
      {:module, module, _bytecode, _} =
        Module.create(
          module_name,
          quote do
            @moduledoc false
            use GRPC.Endpoint

            intercept(Snakepit.GRPC.Interceptors.ServerLogger, level: :info)
            run(Snakepit.GRPC.BridgeServer)
          end,
          Macro.Env.location(__ENV__)
        )

      module
    end
  end

  defp endpoint_identifier do
    instance_name = Config.instance_name()
    instance_token = Config.instance_token()
    name_identifier = Config.instance_name_identifier()
    token_identifier = Config.instance_token_identifier()
    node_name = node() |> to_string()

    if is_nil(instance_name) and is_nil(instance_token) and node() == :nonode@nohost do
      SLog.warning(
        @log_category,
        "No instance_name or instance_token set and node is :nonode@nohost; " <>
          "gRPC listener names may collide"
      )
    end

    identifier =
      [name_identifier, token_identifier]
      |> Enum.filter(&present_identifier?/1)
      |> Enum.join("__")
      |> case do
        "" -> nil
        value -> value
      end

    identifier || node_name || "default"
  end

  defp present_identifier?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_identifier?(_), do: false

  defp endpoint_suffix(identifier) do
    sanitized =
      identifier
      |> to_string()
      |> String.trim()
      |> String.replace(~r/[^a-zA-Z0-9_]/, "_")

    sanitized = if sanitized == "", do: "default", else: sanitized
    short = String.slice(sanitized, 0, 24)
    hash = :erlang.phash2(sanitized)

    "Instance_#{short}_#{hash}"
  end
end
