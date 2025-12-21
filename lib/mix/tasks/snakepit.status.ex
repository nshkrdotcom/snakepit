defmodule Mix.Tasks.Snakepit.Status do
  @moduledoc """
  Report the current status of Snakepit pools and worker queues.
  """

  use Mix.Task

  @shortdoc "Show Snakepit pool status"

  @impl true
  def run(_args) do
    ensure_started!()

    pooling_enabled = Application.get_env(:snakepit, :pooling_enabled, false)

    if pooling_enabled do
      report_pool_status()
    else
      Mix.shell().info("Snakepit pooling is disabled (set :pooling_enabled to true).")
    end
  end

  defp ensure_started! do
    case Application.ensure_all_started(:snakepit) do
      {:ok, _apps} -> :ok
      {:error, {app, reason}} -> Mix.raise("Failed to start #{app}: #{inspect(reason)}")
    end
  end

  defp report_pool_status do
    Mix.shell().info("Snakepit pool status")
    Mix.shell().info(String.duplicate("-", 32))

    case Snakepit.Config.get_pool_configs() do
      {:ok, pools} ->
        Enum.each(pools, &print_pool_status/1)

      {:error, reason} ->
        Mix.raise("Unable to load pool configuration: #{inspect(reason)}")
    end
  end

  defp print_pool_status(%{name: pool_name} = pool_config) do
    workers =
      case Snakepit.Pool.list_workers(Snakepit.Pool, pool_name) do
        {:error, :pool_not_found} -> []
        list -> list
      end

    stats =
      case Snakepit.Pool.get_stats(Snakepit.Pool, pool_name) do
        {:error, :pool_not_found} -> %{}
        map -> map
      end

    profile = Map.get(pool_config, :worker_profile, :process)

    Mix.shell().info("")
    Mix.shell().info("Pool: #{pool_name} (#{profile})")
    Mix.shell().info("  Workers: #{length(workers)}")
    Mix.shell().info("  Queued: #{Map.get(stats, :queued, 0)}")
    Mix.shell().info("  Requests: #{Map.get(stats, :requests, 0)}")
    Mix.shell().info("  Errors: #{Map.get(stats, :errors, 0)}")
    Mix.shell().info("  Queue timeouts: #{Map.get(stats, :queue_timeouts, 0)}")
  end
end
