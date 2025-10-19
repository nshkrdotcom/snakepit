# Integrating Snakepit Into a Host Supervisor Tree  
_Created: 2025-10-18_  

## Goal

Provide a repeatable pattern for embedding Snakepit inside another OTP application’s supervision tree while preserving the bridge’s resilience guarantees and keeping host application restarts independent from Snakepit’s worker churn.

## High-Level Strategy

- Treat Snakepit as a self-contained subsystem managed by its own supervisors. The host app should start Snakepit under a dedicated subtree (usually via `Snakepit.Application` or a light wrapper) rather than sprinkling individual Snakepit processes across the host tree.  
- Use a boundary supervisor (e.g., `MyApp.SnakepitSupervisor`) configured as `:rest_for_one` or `:one_for_all` depending on coupling requirements. This boundary owns Snakepit’s application module plus any host-specific adapters (metrics, config sync).  
- Keep host critical services (HTTP endpoints, schedulers, ingestion pipelines) outside the Snakepit subtree. When Python workers churn, the rest of the app must stay available.  
- Prefer delegating lifecycle operations to existing Snakepit APIs (`Snakepit.Pool`, `Snakepit.WorkerLifecycle`) instead of directly manipulating the underlying supervisors.  

## Reference Topology

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    snakepit_children = [
      {Snakepit.Application, Application.fetch_env!(:my_app, :snakepit)}
    ]

    host_children = [
      MyApp.Telemetry,
      {MyApp.Endpoint, []},
      MyApp.JobSupervisor
    ]

    Supervisor.start_link(
      [
        {MyApp.SnakepitSupervisor, snakepit_children},
        {MyApp.CoreSupervisor, host_children}
      ],
      strategy: :one_for_one,
      name: MyApp.Supervisor
    )
  end
end
```

```elixir
defmodule MyApp.SnakepitSupervisor do
  use Supervisor

  def start_link(children) do
    Supervisor.start_link(__MODULE__, children, name: __MODULE__)
  end

  @impl true
  def init(children) do
    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 5, max_seconds: 10)
  end
end
```

### Notes

- The wrapper supervisor isolates Snakepit restarts while still allowing host-specific instrumentation (e.g., telemetry handlers) to live beside it.  
- `Snakepit.Application` accepts the same configuration map as when running standalone; pass values from `config/runtime.exs` for environment-specific tuning.  
- If you need to hook into Snakepit events (e.g., to publish worker metrics), start those handlers under `MyApp.SnakepitSupervisor` so they restart with Snakepit when necessary.  

## Configuration Guidance

- Load Snakepit config via the host app’s runtime config. Example:
  ```elixir
  config :my_app, :snakepit,
    grpc_port: 50_051,
    pool: [size: 8, heartbeat: [interval_ms: 5_000, timeout_ms: 15_000]],
    python: [venv: "/opt/my_app/venv"]
  ```
- Ensure the host app’s release tooling includes Snakepit’s priv assets (`priv/python`, `priv/proto`). When using `mix release`, configure `{:snakepit, otp_app: :snakepit}` so assets are copied.  
- For heartbeat or watchdog enablement, propagate settings through the config map; Snakepit supervisors will distribute them to worker children. Avoid reimplementing heartbeat logic at the host level.  

## Operational Considerations

- **Boot Ordering:** Start Snakepit before components that depend on bridge availability (e.g., job routers). Use supervisor dependencies or wait-for-ready checks via telemetry to ensure downstream services only proceed once Snakepit reports ready.  
- **Observability:** Register host-specific telemetry handlers for `[:snakepit, :pool, :worker, :state_change]` events to integrate with existing dashboards. Keep handlers lightweight to avoid slowing down Snakepit supervisors.  
- **Error Handling:** When Snakepit is unavailable, degrade gracefully (queue work, surface partial availability). Do not crash host supervisors on transient worker failures; rely on Snakepit restart budgets instead.  
- **Deployment:** Regenerate gRPC stubs (`mix grpc.gen`, `make proto-python`) in CI/CD whenever protos change so the host release bundles matching code. Validate with `make test` before cutover.  

## Checklist for New Integrations

- [ ] Wrapper supervisor created and linked under the host app’s root tree.  
- [ ] Snakepit configuration provided via host runtime config and validated during boot.  
- [ ] Host observability hooks registered, tested with simulated worker crash.  
- [ ] Release packaging includes Snakepit priv assets and Python dependencies.  
- [ ] Integration tests cover host service behaviour when Snakepit is unavailable or restarting.  
