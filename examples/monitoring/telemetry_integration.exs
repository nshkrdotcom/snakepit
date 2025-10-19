#!/usr/bin/env elixir
#
# Telemetry Integration Demo
#
# Demonstrates how to integrate Snakepit's telemetry events with
# monitoring systems (Prometheus, LiveDashboard, custom handlers).
#
# Shows:
# 1. Attaching telemetry handlers
# 2. Listening for worker lifecycle events
# 3. Tracking pool saturation
# 4. Request performance monitoring
# 5. Custom metrics aggregation
#
# Usage:
#   mix run examples/monitoring/telemetry_integration.exs
#

# Disable automatic pooling to avoid port conflicts
Application.put_env(:snakepit, :pooling_enabled, false)

Code.require_file("../mix_bootstrap.exs", __DIR__)

Snakepit.Examples.Bootstrap.ensure_mix!([
  {:snakepit, path: "."}
])

defmodule TelemetryIntegrationDemo do
  require Logger

  def run do
    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("Snakepit Telemetry Integration Demo")
    IO.puts(String.duplicate("=", 70) <> "\n")

    # Demo 1: Basic telemetry attachment
    demo_basic_telemetry()

    # Demo 2: Metrics aggregation
    demo_metrics_aggregation()

    # Demo 3: Prometheus integration
    demo_prometheus_integration()

    # Demo 4: LiveDashboard integration
    demo_livedashboard_integration()

    # Demo 5: Custom alerting
    demo_custom_alerting()

    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("Telemetry Demo Complete!")
    IO.puts(String.duplicate("=", 70) <> "\n")
  end

  defp demo_basic_telemetry do
    IO.puts("Demo 1: Basic Telemetry Handlers")
    IO.puts(String.duplicate("-", 70))

    IO.puts("""
    Attach handlers in your application:

    # lib/my_app/application.ex
    def start(_type, _args) do
      # Attach before starting Snakepit
      attach_snakepit_handlers()

      children = [...]
      Supervisor.start_link(children, strategy: :one_for_one)
    end

    defp attach_snakepit_handlers do
      :telemetry.attach_many(
        "snakepit-monitoring",
        [
          [:snakepit, :worker, :recycled],
          [:snakepit, :worker, :health_check_failed],
          [:snakepit, :pool, :saturated],
          [:snakepit, :request, :executed]
        ],
        &handle_snakepit_event/4,
        nil
      )
    end

    defp handle_snakepit_event(event, measurements, metadata, _config) do
      Logger.info("Snakepit Event: \#{inspect(event)}")
      Logger.info("  Measurements: \#{inspect(measurements)}")
      Logger.info("  Metadata: \#{inspect(metadata)}")
    end
    """)
  end

  defp demo_metrics_aggregation do
    IO.puts("\nDemo 2: Metrics Aggregation")
    IO.puts(String.duplicate("-", 70))

    IO.puts("""
    Track metrics using a GenServer:

    defmodule MyApp.SnakepitMetrics do
      use GenServer

      def start_link(_) do
        GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
      end

      def init(_) do
        # Attach telemetry
        :telemetry.attach(
          "metrics-collector",
          [:snakepit, :worker, :recycled],
          fn _event, _m, metadata, _cfg ->
            GenServer.cast(__MODULE__, {:worker_recycled, metadata})
          end,
          nil
        )

        state = %{
          total_recycled: 0,
          recycled_by_reason: %{},
          recycled_by_pool: %{}
        }

        {:ok, state}
      end

      def handle_cast({:worker_recycled, metadata}, state) do
        new_state =
          state
          |> Map.update!(:total_recycled, &(&1 + 1))
          |> update_in(
               [:recycled_by_reason, metadata.reason],
               &((&1 || 0) + 1)
             )
          |> update_in(
               [:recycled_by_pool, metadata.pool],
               &((&1 || 0) + 1)
             )

        {:noreply, new_state}
      end

      def get_stats do
        GenServer.call(__MODULE__, :get_stats)
      end

      def handle_call(:get_stats, _from, state) do
        {:reply, state, state}
      end
    end

    # Usage
    iex> MyApp.SnakepitMetrics.get_stats()
    %{
      total_recycled: 42,
      recycled_by_reason: %{
        ttl_expired: 30,
        max_requests: 10,
        manual: 2
      },
      recycled_by_pool: %{
        api_pool: 35,
        hpc_pool: 7
      }
    }
    """)
  end

  defp demo_prometheus_integration do
    IO.puts("\nDemo 3: Prometheus Integration")
    IO.puts(String.duplicate("-", 70))

    IO.puts("""
    Using TelemetryMetricsPrometheus:

    # mix.exs
    {:telemetry_metrics_prometheus_core, "~> 1.1"}

    # lib/my_app/telemetry.ex
    defmodule MyApp.Telemetry do
      use Supervisor
      import Telemetry.Metrics

      def start_link(arg) do
        Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
      end

      def init(_arg) do
        children = [
          {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},
          {TelemetryMetricsPrometheus.Core, metrics: metrics()}
        ]

        Supervisor.init(children, strategy: :one_for_one)
      end

      defp metrics do
        [
          # Worker recycling counter
          counter("snakepit.worker.recycled.total",
            tags: [:pool, :reason],
            description: "Total workers recycled"
          ),

          # Worker uptime distribution
          distribution("snakepit.worker.uptime.seconds",
            tags: [:pool],
            buckets: [60, 300, 600, 1800, 3600, 7200],
            description: "Worker uptime when recycled"
          ),

          # Request duration distribution
          distribution("snakepit.request.duration.microseconds",
            tags: [:pool, :command],
            unit: {:native, :microsecond},
            buckets: [100, 1000, 10_000, 100_000, 1_000_000],
            description: "Request execution time"
          ),

          # Pool saturation gauge
          last_value("snakepit.pool.queue_size",
            tags: [:pool],
            description: "Current queue depth"
          )
        ]
      end

      defp periodic_measurements do
        [
          {Snakepit.Worker.LifecycleManager, :get_stats, []},
          {Snakepit.Pool, :get_stats, []}
        ]
      end
    end

    # Grafana Dashboard Queries:

    # Worker recycling rate
    rate(snakepit_worker_recycled_total[5m])

    # Workers recycled by reason
    sum by (reason) (snakepit_worker_recycled_total)

    # P50, P95, P99 request latency
    histogram_quantile(0.50, snakepit_request_duration_microseconds_bucket)
    histogram_quantile(0.95, snakepit_request_duration_microseconds_bucket)
    histogram_quantile(0.99, snakepit_request_duration_microseconds_bucket)

    # Pool queue depth
    snakepit_pool_queue_size{pool=\"api_pool\"}
    """)
  end

  defp demo_livedashboard_integration do
    IO.puts("\nDemo 4: Phoenix LiveDashboard Integration")
    IO.puts(String.duplicate("-", 70))

    IO.puts("""
    Add to your Phoenix router:

    # lib/my_app_web/router.ex
    import Phoenix.LiveDashboard.Router

    scope "/" do
      pipe_through :browser

      live_dashboard "/dashboard",
        metrics: MyApp.Telemetry,
        additional_pages: [
          snakepit: SnakepitDashboard.Page
        ]
    end

    # Custom Snakepit dashboard page
    defmodule SnakepitDashboard.Page do
      use Phoenix.LiveDashboard.PageBuilder

      @impl true
      def menu_link(_, _) do
        {:ok, "Snakepit Pools"}
      end

      @impl true
      def render(assigns) do
        ~H\"\"\"
        <div>
          <h2>Snakepit Pool Status</h2>
          <%= for pool <- @pools do %>
            <div class="pool-card">
              <h3><%= pool.name %></h3>
              <p>Profile: <%= pool.profile %></p>
              <p>Workers: <%= pool.workers %></p>
              <p>Capacity: <%= pool.capacity %></p>
              <p>Utilization: <%= pool.utilization %>%</p>
            </div>
          <% end %>
        </div>
        \"\"\"
      end

      @impl true
      def mount(_params, _session, socket) do
        pools = get_pool_data()
        {:ok, assign(socket, pools: pools)}
      end

      defp get_pool_data do
        # Use ProfileInspector to get data
        case Snakepit.Diagnostics.ProfileInspector.get_comprehensive_report() do
          {:ok, report} -> report.pools
          _ -> []
        end
      end
    end
    """)
  end

  defp demo_custom_alerting do
    IO.puts("\nDemo 5: Custom Alerting")
    IO.puts(String.duplicate("-", 70))

    IO.puts("""
    Set up alerts for anomalies:

    # Alert on high worker churn
    :telemetry.attach(
      "high-churn-alert",
      [:snakepit, :worker, :recycled],
      fn _event, _measurements, metadata, state ->
        # Track recent events
        now = System.system_time(:second)
        recent = Enum.filter(state.events, fn {time, _} -> now - time < 300 end)
        events = [{now, metadata} | recent]

        # Alert if >10 recycling events in 5 minutes
        if length(events) > 10 do
          send_alert(:high_worker_churn, %{
            count: length(events),
            window: "5 minutes",
            pool: metadata.pool
          })
        end

        %{events: events}
      end,
      %{events: []}
    )

    # Alert on pool saturation
    :telemetry.attach(
      "saturation-alert",
      [:snakepit, :pool, :saturated],
      fn _event, measurements, metadata, _config ->
        if measurements.queue_size > metadata.max_queue_size * 0.8 do
          send_alert(:pool_near_capacity, %{
            pool: metadata.pool,
            queue_size: measurements.queue_size,
            max: metadata.max_queue_size,
            utilization: measurements.queue_size / metadata.max_queue_size
          })
        end
      end,
      nil
    )

    # Alert on health check failures
    :telemetry.attach(
      "health-failure-alert",
      [:snakepit, :worker, :health_check_failed],
      fn _event, _measurements, metadata, _config ->
        send_alert(:worker_unhealthy, %{
          worker_id: metadata.worker_id,
          pool: metadata.pool,
          reason: metadata.reason
        })
      end,
      nil
    )

    defp send_alert(type, data) do
      # Send to PagerDuty, Slack, email, etc.
      Logger.error(\"ALERT: \#{type} - \#{inspect(data)}\")
      # HTTPoison.post(webhook_url, Jason.encode!(data))
    end
    """)
  end
end

# Run the demo
TelemetryIntegrationDemo.run()
