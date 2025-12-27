# Logging Audit (Phase 0)

This table captures log and console output points discovered in `lib/` and `priv/python/`.

| File | Line | Type | Level | Message Pattern | Should Keep? | Signal/Protocol? | Notes |
|---|---|---|---|---|---|---|---|
| lib/snakepit.ex | 98 | IO | puts | IO.puts("Received: \#{inspect(chunk)}") | Yes | No |  |
| lib/snakepit.ex | 187 | IO | inspect | IO.inspect(result) | Yes | No |  |
| lib/snakepit.ex | 243 | IO | puts | IO.puts("\n[Snakepit] Script execution finished. Shutting down gracefully...") | Yes | No |  |
| lib/snakepit.ex | 260 | IO | puts | IO.puts("[Snakepit] Error: Pool failed to initialize within #{startup_timeout}ms") | Yes | No |  |
| lib/snakepit.ex | 273 | IO | puts | IO.puts("[Snakepit] Restarting to apply script configuration...") | Yes | No |  |
| lib/snakepit.ex | 317 | IO | puts | IO.puts("[Snakepit] #{label} complete (supervisor already terminated).") | Yes | No |  |
| lib/snakepit.ex | 326 | IO | puts | IO.puts("[Snakepit] #{label} complete (confirmed via :DOWN signal).") | Yes | No |  |
| lib/snakepit.ex | 329 | IO | puts | IO.puts( | Yes | No |  |
| lib/snakepit.ex | 350 | IO | puts | IO.puts( | Yes | No |  |
| lib/snakepit.ex | 358 | IO | puts | IO.puts("[Snakepit] Warning: Worker processes still running after forced cleanup.") | Yes | No |  |
| lib/snakepit.ex | 419 | IO | puts | IO.puts( | Yes | No |  |
| lib/snakepit.ex | 424 | IO | puts | IO.puts("[Snakepit] Warning: cleanup crashed: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit.ex | 431 | IO | puts | IO.puts("[Snakepit] Halting BEAM with status #{status}.") | Yes | No |  |
| lib/snakepit/adapters/grpc_python.ex | 30 | IO | puts | IO.puts("Processed: \#{chunk["item"]} - \#{chunk["confidence"]}") | Yes | No |  |
| lib/snakepit/adapters/grpc_python.ex | 38 | IO | puts | IO.puts("Progress: \#{chunk["progress_percent"]}%") | Yes | No |  |
| lib/snakepit/adapters/grpc_python.ex | 158 | SLog | error | SLog.error("gRPC connection failed after all retries") | Yes | No |  |
| lib/snakepit/adapters/grpc_python.ex | 166 | SLog | debug | SLog.debug("gRPC connection established to port #{port}") | Yes | No |  |
| lib/snakepit/adapters/grpc_python.ex | 176 | SLog | debug | SLog.debug( | Yes | No |  |
| lib/snakepit/adapters/grpc_python.ex | 191 | SLog | error | SLog.error( | Yes | No |  |
| lib/snakepit/application.ex | 54 | SLog | info | SLog.info( | Yes | No |  |
| lib/snakepit/application.ex | 66 | SLog | info | SLog.info("OTLP telemetry enabled (SNAKEPIT_ENABLE_OTLP=true)") | Yes | No |  |
| lib/snakepit/application.ex | 69 | SLog | debug | SLog.debug("OTLP telemetry disabled (set SNAKEPIT_ENABLE_OTLP=true to enable)") | Yes | No |  |
| lib/snakepit/application.ex | 72 | SLog | debug | SLog.debug( | Yes | No |  |
| lib/snakepit/application.ex | 97 | SLog | info | SLog.info("🚀 Starting Snakepit with pooling enabled (size: #{pool_size})") | Yes | No |  |
| lib/snakepit/application.ex | 142 | SLog | info | SLog.info("🔧 Starting Snakepit with pooling disabled") | Yes | No |  |
| lib/snakepit/application.ex | 150 | SLog | debug | SLog.debug("Snakepit.Application started at: #{System.monotonic_time(:millisecond)}") | Yes | No |  |
| lib/snakepit/application.ex | 156 | SLog | debug | SLog.debug("Snakepit.Application.stop/1 called at: #{System.monotonic_time(:millisecond)}") | Yes | No |  |
| lib/snakepit/application.ex | 174 | SLog | warning | SLog.warning("Shutdown cleanup failed: #{inspect(error)}") | Yes | No |  |
| lib/snakepit/application.ex | 177 | SLog | warning | SLog.warning("Shutdown cleanup exited: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/bridge/session_store.ex | 264 | SLog | info | SLog.info("SessionStore started with table #{table}") | Yes | No |  |
| lib/snakepit/bridge/session_store.ex | 306 | SLog | error | SLog.error("Error updating session #{session_id}: #{inspect(error)}") | Yes | No |  |
| lib/snakepit/bridge/session_store.ex | 407 | SLog | warning | SLog.warning("Failed to validate session for worker affinity: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/bridge/session_store.ex | 422 | SLog | warning | SLog.warning("SessionStore received unexpected message: #{inspect(msg)}") | Yes | No |  |
| lib/snakepit/bridge/session_store.ex | 441 | SLog | debug | SLog.debug( | Yes | No |  |
| lib/snakepit/bridge/session_store.ex | 491 | SLog | debug | SLog.debug("Created new session: #{session_id}") | Yes | No |  |
| lib/snakepit/bridge/session_store.ex | 496 | SLog | debug | SLog.debug("Session #{session_id} already exists - reusing (concurrent init)") | Yes | No |  |
| lib/snakepit/bridge/tool_registry.ex | 144 | SLog | info | SLog.info("ToolRegistry started with ETS table: #{@table_name}") | Yes | No |  |
| lib/snakepit/bridge/tool_registry.ex | 166 | SLog | debug | SLog.debug("Registered Elixir tool: #{normalized_name} for session: #{session_id}") | Yes | No |  |
| lib/snakepit/bridge/tool_registry.ex | 198 | SLog | debug | SLog.debug("Registered Python tool: #{normalized_name} for session: #{session_id}") | Yes | No |  |
| lib/snakepit/bridge/tool_registry.ex | 215 | SLog | info | SLog.info("Registered #{length(names)} tools for session: #{session_id}") | Yes | No |  |
| lib/snakepit/bridge/tool_registry.ex | 229 | SLog | debug | SLog.debug("Cleaned up #{num_deleted} tools for session: #{session_id}") | Yes | No |  |
| lib/snakepit/config.ex | 343 | SLog | info | SLog.info("Converted legacy configuration to pool config for :default pool") | Yes | No |  |
| lib/snakepit/error.ex | 37 | Logger | error | Logger.error("Python error: \#{error.message}") | Yes | No |  |
| lib/snakepit/error.ex | 38 | Logger | debug | Logger.debug("Traceback: \#{error.python_traceback}") | Yes | No |  |
| lib/snakepit/grpc/bridge_server.ex | 47 | SLog | debug | SLog.debug("Ping received: #{message}") | Yes | No |  |
| lib/snakepit/grpc/bridge_server.ex | 56 | SLog | info | SLog.info("Initializing session: #{request.session_id}") | Yes | No |  |
| lib/snakepit/grpc/bridge_server.ex | 76 | SLog | info | SLog.info("Cleaning up session: #{session_id}") | Yes | No |  |
| lib/snakepit/grpc/bridge_server.ex | 90 | SLog | debug | SLog.debug("GetSession: #{session_id}") | Yes | No |  |
| lib/snakepit/grpc/bridge_server.ex | 114 | SLog | debug | SLog.debug("Heartbeat: #{session_id}") | Yes | No |  |
| lib/snakepit/grpc/bridge_server.ex | 136 | SLog | info | SLog.info("ExecuteTool: #{request.tool_name} for session #{request.session_id}") | Yes | No |  |
| lib/snakepit/grpc/bridge_server.ex | 185 | SLog | debug | SLog.debug("Executing remote tool #{tool.name} on worker #{tool.worker_id}") | Yes | No |  |
| lib/snakepit/grpc/bridge_server.ex | 201 | SLog | error | SLog.error("Failed to execute remote tool #{tool.name}: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/grpc/bridge_server.ex | 209 | SLog | error | SLog.error("Failed to execute remote tool #{tool.name}: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/grpc/bridge_server.ex | 464 | SLog | warning | SLog.warning( | Yes | No |  |
| lib/snakepit/grpc/bridge_server.ex | 508 | SLog | info | SLog.info("RegisterTools for session #{request.session_id}, worker: #{request.worker_id}") | Yes | No |  |
| lib/snakepit/grpc/bridge_server.ex | 549 | SLog | debug | SLog.debug("GetExposedElixirTools for session #{session_id}") | Yes | No |  |
| lib/snakepit/grpc/bridge_server.ex | 588 | SLog | info | SLog.info("ExecuteElixirTool: #{request.tool_name} for session #{request.session_id}") | Yes | No |  |
| lib/snakepit/grpc/client_impl.ex | 205 | SLog | error | SLog.error("gRPC error: #{inspect(error)}") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 28 | IO | puts | IO.puts("Processed: \#{chunk["item"]}") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 259 | SLog | debug | SLog.debug("Pool.Registry missing entry for #{worker_id} while attaching metadata") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 308 | SLog | error | SLog.error("Failed to reserve worker slot for #{worker_id}: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 314 | SLog | debug | SLog.debug("Reserved worker slot for #{worker_id}") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 376 | SLog | info | SLog.info( | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 490 | SLog | info | SLog.info("Started gRPC server process, will listen on TCP port #{port}") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 494 | SLog | error | SLog.error("Failed to get gRPC server process PID: #{inspect(error)}") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 507 | SLog | debug | SLog.debug( | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 512 | SLog | error | SLog.error( | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 574 | SLog | info | SLog.info("✅ gRPC worker #{state.id} initialization complete and acknowledged.") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 622 | SLog | debug | SLog.debug("gRPC server exited during startup with status #{status} (shutdown)") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 626 | SLog | debug | SLog.debug( | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 633 | SLog | debug | SLog.debug("Pool handshake failed for worker #{state.id}: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 637 | SLog | error | SLog.error("Failed to connect to gRPC server: #{reason}") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 641 | SLog | error | SLog.error("Failed to start gRPC server: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 683 | SLog | debug | SLog.debug("[GRPCWorker] execute_stream #{command} with args #{Redaction.describe(args)}") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 697 | SLog | debug | SLog.debug("[GRPCWorker] execute_stream result: #{Redaction.describe(result)}") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 800 | SLog | warning | SLog.warning("Health check failed: #{reason}") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 809 | SLog | error | SLog.error("External gRPC process died: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 815 | SLog | warning | SLog.warning( | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 831 | SLog | info | SLog.info("gRPC server output: #{trimmed}") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 855 | SLog | error | SLog.error(""" | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 868 | SLog | debug | SLog.debug("Unexpected message: #{inspect(msg)}") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 878 | SLog | debug | SLog.debug( | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 882 | SLog | debug | SLog.debug("gRPC worker #{state.id} terminating: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 921 | SLog | debug | SLog.debug("Starting graceful shutdown of external gRPC process PID: #{state.process_pid}...") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 938 | SLog | debug | SLog.debug("✅ gRPC server PID #{state.process_pid} terminated gracefully") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 941 | SLog | warning | SLog.warning("Failed to gracefully kill #{state.process_pid}: #{inspect(kill_reason)}") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 946 | SLog | warning | SLog.warning( | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 959 | SLog | debug | SLog.debug("✅ Immediately killed gRPC server PID #{state.process_pid}") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 962 | SLog | warning | SLog.warning("Failed to kill #{state.process_pid}: #{inspect(kill_reason)}") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 1063 | SLog | error | SLog.error("Failed to start heartbeat monitor for #{state.id}: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 1123 | SLog | debug | SLog.debug("Heartbeat session initialization failed: #{inspect(exception)}") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 1127 | SLog | debug | SLog.debug("Heartbeat session initialization exited: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 1147 | SLog | debug | SLog.debug("Registered telemetry stream for worker #{state.id}") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 1151 | SLog | warning | SLog.warning( | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 1158 | SLog | warning | SLog.warning( | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 1165 | SLog | debug | SLog.debug("No channel available for telemetry stream registration") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 1454 | SLog | info | #           SLog.info("gRPC worker started successfully on port #{expected_port}") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 1455 | SLog | info | #           SLog.info("gRPC server output: #{String.trim(output)}") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 1500 | SLog | debug | SLog.debug("Python server output during startup: #{String.trim(output)}") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 1530 | SLog | debug | SLog.debug( | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 1535 | SLog | error | SLog.error("Python gRPC server process exited with status #{status} during startup") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 1542 | SLog | error | SLog.error("Python gRPC server port died during startup: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 1547 | SLog | error | SLog.error("Timeout waiting for Python gRPC server to start after #{timeout}ms") | Yes | No |  |
| lib/snakepit/grpc_worker.ex | 1567 | SLog | error | SLog.error("Python server output during startup:\n#{trimmed}") | Yes | No |  |
| lib/snakepit/hardware.ex | 100 | IO | puts | IO.puts("CUDA version: \#{caps.cuda_version}") | Yes | No |  |
| lib/snakepit/hardware.ex | 144 | IO | puts | {:ok, {:cuda, 0}} -> IO.puts("Using CUDA device 0") | Yes | No |  |
| lib/snakepit/hardware.ex | 145 | IO | puts | {:error, :device_not_available} -> IO.puts("CUDA not available") | Yes | No |  |
| lib/snakepit/heartbeat_monitor.ex | 161 | Logger | warning | Logger.warning("Heartbeat ping failed for #{state.worker_id}: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/heartbeat_monitor.ex | 181 | Logger | error | Logger.error(log_message) | Yes | No |  |
| lib/snakepit/heartbeat_monitor.ex | 183 | Logger | warning | Logger.warning("#{log_message} (worker configured as heartbeat-independent)") | Yes | No |  |
| lib/snakepit/heartbeat_monitor.ex | 201 | Logger | debug | Logger.debug("Heartbeat monitor observed worker #{state.worker_id} exit: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/heartbeat_monitor.ex | 207 | Logger | debug | Logger.debug("Unhandled heartbeat monitor message: #{inspect(message)}") | Yes | No |  |
| lib/snakepit/heartbeat_monitor.ex | 255 | Logger | debug | Logger.debug( | Yes | No |  |
| lib/snakepit/logger.ex | 20 | Logger | debug | Logger.debug(message, metadata) | Yes | No |  |
| lib/snakepit/logger.ex | 29 | Logger | info | Logger.info(message, metadata) | Yes | No |  |
| lib/snakepit/logger.ex | 38 | Logger | warning | Logger.warning(message, metadata) | Yes | No |  |
| lib/snakepit/logger.ex | 47 | Logger | error | Logger.error(message, metadata) | Yes | No |  |
| lib/snakepit/pool/application_cleanup.ex | 26 | SLog | info | SLog.info("🛡️ Application cleanup handler started") | Yes | No |  |
| lib/snakepit/pool/application_cleanup.ex | 41 | SLog | info | SLog.info("🔍 Emergency cleanup check (shutdown reason: #{inspect(reason)})") | Yes | No |  |
| lib/snakepit/pool/application_cleanup.ex | 42 | SLog | debug | SLog.debug("ApplicationCleanup.terminate/2 called at: #{System.monotonic_time(:millisecond)}") | Yes | No |  |
| lib/snakepit/pool/application_cleanup.ex | 43 | SLog | debug | SLog.debug("ApplicationCleanup process info: #{inspect(Process.info(self()))}") | Yes | No |  |
| lib/snakepit/pool/application_cleanup.ex | 49 | SLog | info | SLog.info("✅ No orphaned processes - supervision tree cleaned up correctly") | Yes | No |  |
| lib/snakepit/pool/application_cleanup.ex | 53 | SLog | debug | SLog.debug( | Yes | No |  |
| lib/snakepit/pool/application_cleanup.ex | 57 | SLog | debug | SLog.debug("Cleanup: Orphaned PIDs: #{inspect(orphaned_pids)}") | Yes | No |  |
| lib/snakepit/pool/application_cleanup.ex | 65 | SLog | debug | SLog.debug("Cleanup: Killed #{kill_count} orphaned processes") | Yes | No |  |
| lib/snakepit/pool/application_cleanup.ex | 123 | SLog | warning | SLog.warning("PID #{os_pid} not in ProcessRegistry - true orphan") | Yes | No |  |
| lib/snakepit/pool/application_cleanup.ex | 134 | SLog | debug | SLog.debug( | Yes | No |  |
| lib/snakepit/pool/pool.ex | 98 | SLog | debug | SLog.debug("[Pool] execute_stream #{command} with #{Redaction.describe(args)}") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 102 | SLog | debug | SLog.debug("[Pool] Checked out worker #{worker_id} for streaming") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 111 | SLog | debug | SLog.debug("[Pool] Checking in worker #{worker_id} after stream execution") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 119 | SLog | error | SLog.error("[Pool] Failed to checkout worker for streaming: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 135 | SLog | debug | SLog.debug("[Pool] execute_on_worker_stream using #{inspect(worker_module)}") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 138 | SLog | debug | SLog.debug("[Pool] Invoking #{worker_module}.execute_stream with timeout #{timeout}") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 140 | SLog | debug | SLog.debug("[Pool] execute_stream result: #{Redaction.describe(result)}") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 143 | SLog | error | SLog.error("[Pool] Worker module #{worker_module} does not export execute_stream/5") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 340 | SLog | info | SLog.info( | Yes | No |  |
| lib/snakepit/pool/pool.ex | 348 | SLog | info | SLog.info("📊 Baseline resources: #{inspect(baseline_resources)}") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 372 | SLog | info | SLog.info("Initializing pool #{pool_name} with #{pool_state.size} workers...") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 386 | SLog | info | SLog.info("✅ Pool #{pool_name}: Initialized #{length(workers)}/#{pool_state.size} workers") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 392 | SLog | error | SLog.error("❌ Pool #{pool_name} failed to start any workers!") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 423 | SLog | info | SLog.info("✅ All pools initialized in #{elapsed}ms") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 424 | SLog | info | SLog.info("📊 Resource usage delta: #{inspect(resource_delta)}") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 432 | SLog | warning | SLog.warning( | Yes | No |  |
| lib/snakepit/pool/pool.ex | 467 | SLog | error | SLog.error( | Yes | No |  |
| lib/snakepit/pool/pool.ex | 487 | SLog | info | SLog.info("Pool initialization interrupted by shutdown") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 492 | SLog | info | SLog.info("Pool initialization interrupted by shutdown") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 497 | SLog | warning | SLog.warning("Pool initialization process killed") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 502 | SLog | error | SLog.error("Pool initialization failed: #{inspect(other)}") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 528 | SLog | debug | SLog.debug("Removed timed out request #{inspect(from)} from queue in pool #{pool_name}") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 545 | SLog | debug | SLog.debug( | Yes | No |  |
| lib/snakepit/pool/pool.ex | 585 | SLog | debug | SLog.debug("Pool received unexpected message: #{inspect(msg)}") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 741 | SLog | info | SLog.info("Worker #{worker_id} reported ready. Processing queued work.") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 748 | SLog | error | SLog.error("Worker #{worker_id} reported ready but pool #{pool_name} not found!") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 904 | SLog | debug | SLog.debug("Client was already down; skipping work on worker #{worker_id}") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 953 | SLog | warning | SLog.warning( | Yes | No |  |
| lib/snakepit/pool/pool.ex | 1045 | SLog | error | SLog.error("checkin_worker: pool #{pool_name} not found!") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 1135 | SLog | debug | SLog.debug("Skipping cancelled request from #{inspect(queued_from)}") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 1192 | SLog | warning | SLog.warning("Queued client #{inspect(client_pid)} died during execution.") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 1222 | SLog | debug | SLog.debug("Discarding request from dead client #{inspect(client_pid)}") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 1236 | SLog | error | SLog.error("Worker #{worker_id} (pid: #{inspect(pid)}) died: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 1243 | SLog | warning | SLog.warning("Dead worker #{worker_id} belongs to unknown pool #{pool_name}") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 1253 | SLog | debug | SLog.debug("Removed dead worker #{worker_id} from pool #{pool_name}") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 1291 | SLog | info | SLog.info("🛑 Pool manager terminating with reason: #{inspect(reason)}.") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 1295 | SLog | debug | SLog.debug(""" | Yes | No |  |
| lib/snakepit/pool/pool.ex | 1306 | SLog | warning | SLog.warning( | Yes | No |  |
| lib/snakepit/pool/pool.ex | 1449 | SLog | info | SLog.info("Initializing #{length(configs)} pool(s)") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 1453 | SLog | warning | SLog.warning("No pool configs found, using legacy defaults") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 1457 | SLog | error | SLog.error("Pool configuration error: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 1499 | SLog | warning | SLog.warning( | Yes | No |  |
| lib/snakepit/pool/pool.ex | 1503 | SLog | warning | SLog.warning("⚠️  To increase this limit, set :pool_config.max_workers in config/config.exs") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 1510 | SLog | info | SLog.info("🚀 Starting concurrent initialization of #{actual_count} workers...") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 1511 | SLog | info | SLog.info("📦 Using worker type: #{inspect(worker_module)}") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 1573 | SLog | info | SLog.info("Starting batch #{batch_num + 1}: workers #{batch_start}-#{batch_end}") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 1589 | SLog | warning | SLog.warning("Skipping batch #{batch_num + 1}: WorkerSupervisor terminated during startup") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 1683 | SLog | info | SLog.info("✅ Worker #{i}/#{actual_count} ready: #{worker_id}") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 1687 | SLog | error | SLog.error("❌ Worker #{i}/#{actual_count} failed: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 1695 | SLog | error | SLog.error("Worker startup task failed: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 1743 | SLog | debug | SLog.debug("Using preferred worker #{preferred_worker_id} for session #{session_id}") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 1952 | SLog | warning | SLog.warning("Worker #{inspect(pid)} not found in capacity store") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 2016 | SLog | debug | SLog.debug("Stored session affinity: #{session_id} -> #{worker_id}") | Yes | No |  |
| lib/snakepit/pool/pool.ex | 2272 | SLog | warning | SLog.warning( | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 249 | SLog | error | SLog.error("Failed to open DETS file: #{inspect(reason)}. Deleting and recreating...") | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 271 | SLog | info | SLog.info( | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 312 | SLog | info | SLog.info( | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 331 | SLog | debug | SLog.debug( | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 338 | SLog | info | SLog.info("🚮 Unregistered worker #{worker_id} with external process PID #{process_pid}") | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 347 | SLog | debug | SLog.debug( | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 379 | SLog | debug | SLog.debug( | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 402 | SLog | info | SLog.info("Reserved worker slot #{worker_id} for BEAM run #{state.beam_run_id}") | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 471 | SLog | info | SLog.info("Manual orphan cleanup triggered") | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 513 | SLog | info | SLog.info("Cleaned up #{dead_count} dead worker entries") | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 537 | SLog | debug | SLog.debug("ProcessRegistry received unexpected message: #{inspect(msg)}") | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 554 | SLog | info | SLog.info("🚮 Unregistered worker #{worker_id} with external process PID #{process_pid}") | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 560 | SLog | info | SLog.info("Snakepit Pool Process Registry terminating: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 564 | SLog | info | SLog.info("ProcessRegistry terminating with #{length(all_entries)} entries in DETS") | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 592 | SLog | debug | SLog.debug( | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 597 | SLog | info | SLog.info("Total entries in DETS: #{length(all_entries)}") | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 600 | SLog | info | SLog.info("Found #{length(stale_entries)} stale entries to remove (from previous runs)") | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 603 | SLog | info | SLog.info("Found #{length(old_run_orphans)} active processes from previous BEAM runs") | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 606 | SLog | info | SLog.info("Found #{length(abandoned_reservations)} abandoned reservations") | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 650 | SLog | info | SLog.info("Entry is stale: BEAM OS PID #{info.beam_os_pid} is dead") | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 705 | SLog | debug | SLog.debug("Orphaned entry #{worker_id} with PID #{info.process_pid} already dead") | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 711 | SLog | warning | SLog.warning( | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 723 | SLog | debug | SLog.debug("Process #{process_pid} not found, already dead") | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 742 | SLog | warning | SLog.warning( | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 749 | SLog | info | SLog.info("Confirmed PID #{process_pid} is a grpc_server process with matching run_id") | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 753 | SLog | info | SLog.info("Process #{process_pid} successfully terminated") | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 756 | SLog | error | SLog.error("Failed to kill process #{process_pid}: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 762 | SLog | warning | SLog.warning( | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 767 | SLog | debug | SLog.debug("PID #{process_pid} is not a grpc_server process, skipping: #{String.trim(cmd)}") | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 780 | SLog | debug | SLog.debug( | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 786 | SLog | info | SLog.info("Killed #{count} processes for run #{info.beam_run_id}") | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 808 | SLog | info | SLog.info( | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 823 | SLog | info | SLog.info("Skipping rogue process cleanup (disabled via :rogue_cleanup config)") | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 837 | SLog | info | SLog.info("Found #{length(owned_processes)} snakepit grpc_server processes with run markers") | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 873 | SLog | warning | SLog.warning( | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 877 | SLog | warning | SLog.warning("Rogue PIDs: #{inspect(rogue_pids)}") | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 887 | SLog | warning | SLog.warning("Killing rogue process #{pid}: #{String.trim(cmd)}") | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 894 | SLog | error | SLog.error("Failed to kill rogue process #{pid}: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 954 | SLog | info | SLog.info("Loaded #{length(current_processes)} processes from current BEAM run") | Yes | No |  |
| lib/snakepit/pool/process_registry.ex | 979 | SLog | info | SLog.info( | Yes | No |  |
| lib/snakepit/pool/registry.ex | 117 | Logger | debug | Logger.debug( | Yes | No |  |
| lib/snakepit/pool/registry.ex | 125 | Logger | debug | Logger.debug( | Yes | No |  |
| lib/snakepit/pool/worker_starter.ex | 129 | SLog | debug | SLog.debug("Aborting worker starter for #{worker_id} - Global pool is dead") | Yes | No |  |
| lib/snakepit/pool/worker_starter.ex | 142 | SLog | debug | SLog.debug("Starting worker starter for #{worker_id} with module #{inspect(worker_module)}") | Yes | No |  |
| lib/snakepit/pool/worker_supervisor.ex | 58 | SLog | info | SLog.info("Started worker starter for #{worker_id} with PID #{inspect(starter_pid)}") | Yes | No |  |
| lib/snakepit/pool/worker_supervisor.ex | 62 | SLog | debug | SLog.debug( | Yes | No |  |
| lib/snakepit/pool/worker_supervisor.ex | 69 | SLog | error | SLog.error("Failed to start worker starter for #{worker_id}: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/pool/worker_supervisor.ex | 179 | SLog | debug | SLog.debug("Resources released for #{worker_id}, safe to restart") | Yes | No |  |
| lib/snakepit/pool/worker_supervisor.ex | 199 | SLog | debug | SLog.debug("Probing port #{port_to_probe} before restarting #{worker_id}") | Yes | No |  |
| lib/snakepit/pool/worker_supervisor.ex | 209 | SLog | info | SLog.info( | Yes | No |  |
| lib/snakepit/pool/worker_supervisor.ex | 233 | SLog | warning | SLog.warning( | Yes | No |  |
| lib/snakepit/process_killer.ex | 67 | SLog | debug | SLog.debug( | Yes | No |  |
| lib/snakepit/process_killer.ex | 88 | SLog | warning | SLog.warning("Failed to execute kill command: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/process_killer.ex | 120 | SLog | warning | SLog.warning("Failed to execute kill command: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/process_killer.ex | 295 | SLog | warning | SLog.warning("🔪 Killing all processes with run_id: #{run_id}") | Yes | No |  |
| lib/snakepit/process_killer.ex | 296 | SLog | debug | SLog.debug("kill_by_run_id called at: #{System.monotonic_time(:millisecond)}") | Yes | No |  |
| lib/snakepit/process_killer.ex | 298 | SLog | debug | SLog.debug("Called from: #{inspect(caller_info)}") | Yes | No |  |
| lib/snakepit/process_killer.ex | 321 | SLog | info | SLog.info("Found #{length(matching_pids)} processes to kill") | Yes | No |  |
| lib/snakepit/process_killer.ex | 331 | SLog | warning | SLog.warning("Failed to kill #{pid}: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/process_killer.ex | 424 | SLog | warning | SLog.warning("ps command not available; skipping python process discovery") | Yes | No |  |
| lib/snakepit/process_killer.ex | 453 | SLog | debug | SLog.debug("✅ Process #{os_pid} terminated gracefully") | Yes | No |  |
| lib/snakepit/process_killer.ex | 457 | SLog | warning | SLog.warning("⏰ Process #{os_pid} didn't die, escalating to SIGKILL") | Yes | No |  |
| lib/snakepit/process_killer.ex | 473 | SLog | debug | SLog.debug("✅ Process group #{pgid} terminated gracefully") | Yes | No |  |
| lib/snakepit/process_killer.ex | 476 | SLog | warning | SLog.warning("⏰ Process group #{pgid} didn't die, escalating to SIGKILL") | Yes | No |  |
| lib/snakepit/runtime_cleanup.ex | 48 | SLog | warning | SLog.warning( | Yes | No |  |
| lib/snakepit/runtime_cleanup.ex | 86 | SLog | warning | SLog.warning("Failed to send #{signal} to #{format_target(target)}: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/runtime_cleanup.ex | 153 | SLog | warning | SLog.warning("Cleanup incomplete: #{length(still_alive)} processes still alive after SIGKILL") | Yes | No |  |
| lib/snakepit/telemetry.ex | 213 | SLog | info | SLog.info("Session created: #{metadata.session_id}") | Yes | No |  |
| lib/snakepit/telemetry.ex | 217 | SLog | debug | SLog.debug("Session accessed: #{metadata.session_id}") | Yes | No |  |
| lib/snakepit/telemetry.ex | 221 | SLog | info | SLog.info("Session deleted: #{metadata.session_id}") | Yes | No |  |
| lib/snakepit/telemetry.ex | 225 | SLog | info | SLog.info("Sessions expired: count=#{measurements.count}") | Yes | No |  |
| lib/snakepit/telemetry.ex | 230 | SLog | debug | SLog.debug("Program stored: #{metadata.program_id} in session #{metadata.session_id}") | Yes | No |  |
| lib/snakepit/telemetry.ex | 234 | SLog | debug | SLog.debug("Program retrieved: #{metadata.program_id} from session #{metadata.session_id}") | Yes | No |  |
| lib/snakepit/telemetry.ex | 238 | SLog | debug | SLog.debug("Program deleted: #{metadata.program_id} from session #{metadata.session_id}") | Yes | No |  |
| lib/snakepit/telemetry.ex | 243 | Logger | debug | Logger.debug("Heartbeat monitor started for #{metadata.worker_id}") | Yes | No |  |
| lib/snakepit/telemetry.ex | 247 | Logger | debug | Logger.debug( | Yes | No |  |
| lib/snakepit/telemetry.ex | 253 | Logger | warning | Logger.warning( | Yes | No |  |
| lib/snakepit/telemetry.ex | 259 | Logger | debug | Logger.debug("Heartbeat ping sent for #{metadata.worker_id} (count=#{measurements[:count]})") | Yes | No |  |
| lib/snakepit/telemetry.ex | 263 | Logger | debug | Logger.debug( | Yes | No |  |
| lib/snakepit/telemetry.ex | 269 | Logger | warning | Logger.warning("Heartbeat timeout for #{metadata.worker_id} missed=#{measurements[:count]}") | Yes | No |  |
| lib/snakepit/telemetry.ex | 274 | SLog | debug | SLog.debug( | Yes | No |  |
| lib/snakepit/telemetry/grpc_stream.ex | 57 | Logger | debug | Logger.debug( | Yes | No |  |
| lib/snakepit/telemetry/grpc_stream.ex | 129 | Logger | info | Logger.info( | Yes | No |  |
| lib/snakepit/telemetry/grpc_stream.ex | 138 | Logger | warning | Logger.warning( | Yes | No |  |
| lib/snakepit/telemetry/grpc_stream.ex | 162 | Logger | debug | Logger.debug("Telemetry stream unregistered for worker #{worker_id}", | Yes | No |  |
| lib/snakepit/telemetry/grpc_stream.ex | 174 | Logger | debug | Logger.debug("Cannot update sampling for unknown worker #{worker_id}") | Yes | No |  |
| lib/snakepit/telemetry/grpc_stream.ex | 183 | Logger | debug | Logger.debug("Updated sampling for worker #{worker_id} to #{rate}", | Yes | No |  |
| lib/snakepit/telemetry/grpc_stream.ex | 192 | Logger | warning | Logger.warning( | Yes | No |  |
| lib/snakepit/telemetry/grpc_stream.ex | 217 | Logger | debug | Logger.debug("Toggled telemetry for worker #{worker_id} to #{enabled}", | Yes | No |  |
| lib/snakepit/telemetry/grpc_stream.ex | 225 | Logger | warning | Logger.warning( | Yes | No |  |
| lib/snakepit/telemetry/grpc_stream.ex | 250 | Logger | debug | Logger.debug("Updated filters for worker #{worker_id}", worker_id: worker_id) | Yes | No |  |
| lib/snakepit/telemetry/grpc_stream.ex | 255 | Logger | warning | Logger.warning( | Yes | No |  |
| lib/snakepit/telemetry/grpc_stream.ex | 292 | Logger | debug | Logger.debug("Telemetry stream consumer task terminated: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/telemetry/grpc_stream.ex | 298 | Logger | debug | Logger.debug("Telemetry stream HTTP response received", status: status, headers: headers) | Yes | No |  |
| lib/snakepit/telemetry/grpc_stream.ex | 310 | Logger | debug | Logger.debug("Telemetry stream HTTP connection closed by gun") | Yes | No |  |
| lib/snakepit/telemetry/grpc_stream.ex | 316 | Logger | debug | Logger.debug("Telemetry stream HTTP error from gun", reason: reason) | Yes | No |  |
| lib/snakepit/telemetry/grpc_stream.ex | 384 | Logger | warning | Logger.warning( | Yes | No |  |
| lib/snakepit/telemetry/grpc_stream.ex | 391 | Logger | debug | Logger.debug("Telemetry stream trailers: #{inspect(trailers)}", | Yes | No |  |
| lib/snakepit/telemetry/grpc_stream.ex | 396 | Logger | debug | Logger.debug("Telemetry stream completed for worker #{worker_ctx.worker_id}", | Yes | No |  |
| lib/snakepit/telemetry/grpc_stream.ex | 424 | Logger | debug | if shutdown_reason?(reason), do: &Logger.debug/2, else: &Logger.warning/2 | Yes | No |  |
| lib/snakepit/telemetry/grpc_stream.ex | 461 | Logger | debug | Logger.debug( | Yes | No |  |
| lib/snakepit/telemetry/handlers/logger.ex | 201 | Logger | log | Logger.log(level, message) | Yes | No |  |
| lib/snakepit/telemetry/open_telemetry.ex | 37 | Logger | warning | Logger.warning( | Yes | No |  |
| lib/snakepit/telemetry/open_telemetry.ex | 150 | Logger | error | Logger.error( | Yes | No |  |
| lib/snakepit/telemetry/open_telemetry.ex | 178 | Logger | warning | Logger.warning( | Yes | No |  |
| lib/snakepit/telemetry/open_telemetry.ex | 198 | Logger | debug | Logger.debug("OpenTelemetry start handler failed: #{Exception.message(error)}") | Yes | No |  |
| lib/snakepit/telemetry/open_telemetry.ex | 223 | Logger | debug | Logger.debug("OpenTelemetry stop handler failed: #{Exception.message(error)}") | Yes | No |  |
| lib/snakepit/telemetry/open_telemetry.ex | 247 | Logger | debug | Logger.debug("OpenTelemetry exception handler failed: #{Exception.message(error)}") | Yes | No |  |
| lib/snakepit/telemetry/open_telemetry.ex | 263 | Logger | debug | Logger.debug("Heartbeat OpenTelemetry event failed: #{Exception.message(error)}") | Yes | No |  |
| lib/snakepit/worker/lifecycle_manager.ex | 143 | SLog | info | SLog.info("Worker LifecycleManager started") | Yes | No |  |
| lib/snakepit/worker/lifecycle_manager.ex | 173 | SLog | debug | SLog.debug( | Yes | No |  |
| lib/snakepit/worker/lifecycle_manager.ex | 183 | SLog | debug | SLog.debug("Untracked worker #{worker_id}") | Yes | No |  |
| lib/snakepit/worker/lifecycle_manager.ex | 200 | SLog | info | SLog.info( | Yes | No |  |
| lib/snakepit/worker/lifecycle_manager.ex | 216 | SLog | debug | SLog.debug("Worker #{worker_id} already recycled") | Yes | No |  |
| lib/snakepit/worker/lifecycle_manager.ex | 220 | SLog | info | SLog.info("Recycling worker #{worker_id} (reason: #{reason})") | Yes | No |  |
| lib/snakepit/worker/lifecycle_manager.ex | 242 | SLog | info | SLog.info("Manual recycle requested for worker #{worker_id}") | Yes | No |  |
| lib/snakepit/worker/lifecycle_manager.ex | 347 | SLog | debug | SLog.debug("Worker #{worker_id} (#{inspect(pid)}) died: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/worker/lifecycle_manager.ex | 349 | SLog | warning | SLog.warning("Worker #{worker_id} (#{inspect(pid)}) died: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/worker/lifecycle_manager.ex | 415 | SLog | warning | SLog.warning( | Yes | No |  |
| lib/snakepit/worker/lifecycle_manager.ex | 425 | SLog | info | SLog.info("Worker #{worker_id} TTL expired, recycling...") | Yes | No |  |
| lib/snakepit/worker/lifecycle_manager.ex | 429 | SLog | info | SLog.info("Worker #{worker_id} reached max requests, recycling...") | Yes | No |  |
| lib/snakepit/worker/lifecycle_manager.ex | 436 | SLog | info | SLog.info( | Yes | No |  |
| lib/snakepit/worker/lifecycle_manager.ex | 442 | SLog | info | SLog.info("Worker #{worker_id} recycling due to #{inspect(other_reason)}") | Yes | No |  |
| lib/snakepit/worker/lifecycle_manager.ex | 457 | SLog | debug | SLog.debug("Stopping worker #{worker_id} for recycling...") | Yes | No |  |
| lib/snakepit/worker/lifecycle_manager.ex | 465 | SLog | debug | SLog.debug("Worker #{worker_id} stopped successfully") | Yes | No |  |
| lib/snakepit/worker/lifecycle_manager.ex | 470 | SLog | info | SLog.info("Worker #{worker_id} recycled successfully (new PID: #{inspect(new_pid)})") | Yes | No |  |
| lib/snakepit/worker/lifecycle_manager.ex | 475 | SLog | error | SLog.error("Failed to start replacement for #{worker_id}: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/worker/lifecycle_manager.ex | 480 | SLog | error | SLog.error("Failed to stop worker #{worker_id}: #{inspect(error)}") | Yes | No |  |
| lib/snakepit/worker/lifecycle_manager.ex | 516 | SLog | debug | SLog.debug("Worker #{worker_id} health check passed") | Yes | No |  |
| lib/snakepit/worker/lifecycle_manager.ex | 519 | SLog | warning | SLog.warning("Worker #{worker_id} health check failed: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/worker_profile/process.ex | 63 | SLog | debug | SLog.debug("Process profile started worker #{worker_id}: #{inspect(pid)}") | Yes | No |  |
| lib/snakepit/worker_profile/thread.ex | 77 | SLog | info | SLog.info("Starting threaded worker #{worker_id} with #{threads_per_worker} threads") | Yes | No |  |
| lib/snakepit/worker_profile/thread.ex | 78 | SLog | debug | SLog.debug("Thread worker adapter_args: #{Redaction.describe(adapter_args)}") | Yes | No |  |
| lib/snakepit/worker_profile/thread.ex | 97 | SLog | info | SLog.info( | Yes | No |  |
| lib/snakepit/worker_profile/thread.ex | 104 | SLog | error | SLog.error("Failed to start threaded worker #{worker_id}: #{inspect(error)}") | Yes | No |  |
| lib/snakepit/worker_profile/thread.ex | 285 | SLog | warning | SLog.warning("Capacity store failed to start: #{inspect(reason)}") | Yes | No |  |
| lib/snakepit/worker_profile/thread.ex | 393 | SLog | warning | SLog.warning("Worker #{inspect(worker_pid)} not found in capacity store") | Yes | No |  |
| lib/snakepit/worker_profile/thread/capacity_store.ex | 67 | SLog | debug | SLog.debug("Thread capacity store started with ETS table #{inspect(table)}") | Yes | No |  |
| lib/snakepit/zero_copy.ex | 58 | SLog | warning | SLog.warning( | Yes | No |  |
| priv/python/grpc_server.py | 55 | logger | debug | logger.debug("Snakepit process group created") | Yes | No |  |
| priv/python/grpc_server.py | 58 | logger | warning | logger.warning("Failed to create process group: %s", exc) | Yes | No |  |
| priv/python/grpc_server.py | 67 | logger | info | logger.info("Loaded grpc_server.py from %s", __file__) | Yes | No |  |
| priv/python/grpc_server.py | 77 | print | print | print(f"[health-check] Failed to import adapter '{adapter_path}': {exc}", file=sys.stderr) | Convert to logging | No | Health-check output |
| priv/python/grpc_server.py | 80 | print | print | print("[health-check] Python gRPC dependencies loaded successfully.") | Convert to logging | No | Health-check output |
| priv/python/grpc_server.py | 126 | logger | warning | logger.warning("Invalid SNAKEPIT_HEARTBEAT_CONFIG payload; ignoring.") | Yes | No |  |
| priv/python/grpc_server.py | 131 | logger | warning | logger.warning( | Yes | No |  |
| priv/python/grpc_server.py | 155 | logger | warning | logger.warning(f"{method_name} - ValueError: {str(e)}") | Yes | No |  |
| priv/python/grpc_server.py | 159 | logger | info | logger.info(f"{method_name} - NotImplementedError: {str(e)}") | Yes | No |  |
| priv/python/grpc_server.py | 163 | logger | warning | logger.warning(f"{method_name} - TimeoutError: {str(e)}") | Yes | No |  |
| priv/python/grpc_server.py | 167 | logger | warning | logger.warning(f"{method_name} - PermissionError: {str(e)}") | Yes | No |  |
| priv/python/grpc_server.py | 171 | logger | warning | logger.warning(f"{method_name} - FileNotFoundError: {str(e)}") | Yes | No |  |
| priv/python/grpc_server.py | 176 | logger | error | logger.error(f"{error_id} - Unexpected error: {type(e).__name__}: {str(e)}") | Yes | No |  |
| priv/python/grpc_server.py | 177 | logger | error | logger.error(f"{error_id} - Traceback:\n{traceback.format_exc()}") | Yes | No |  |
| priv/python/grpc_server.py | 197 | logger | warning | logger.warning(f"{method_name} - ValueError: {str(e)}") | Yes | No |  |
| priv/python/grpc_server.py | 200 | logger | info | logger.info(f"{method_name} - NotImplementedError: {str(e)}") | Yes | No |  |
| priv/python/grpc_server.py | 204 | logger | error | logger.error(f"{error_id} - Unexpected error: {type(e).__name__}: {str(e)}") | Yes | No |  |
| priv/python/grpc_server.py | 205 | logger | error | logger.error(f"{error_id} - Traceback:\n{traceback.format_exc()}") | Yes | No |  |
| priv/python/grpc_server.py | 230 | logger | debug | logger.debug("BridgeServiceServicer.__init__ called") | Yes | No |  |
| priv/python/grpc_server.py | 238 | logger | debug | logger.debug("Initializing telemetry stream") | Yes | No |  |
| priv/python/grpc_server.py | 243 | logger | info | logger.info("Telemetry backend initialized (gRPC stream)") | Yes | No |  |
| priv/python/grpc_server.py | 248 | logger | debug | logger.debug("Creating async channel to %s", elixir_address) | Yes | No |  |
| priv/python/grpc_server.py | 254 | logger | debug | logger.debug("Creating sync channel to %s", elixir_address) | Yes | No |  |
| priv/python/grpc_server.py | 260 | logger | debug | logger.debug("gRPC channels created successfully") | Yes | No |  |
| priv/python/grpc_server.py | 261 | logger | debug | logger.debug("grpc_server.py __file__=%s", __file__) | Yes | No |  |
| priv/python/grpc_server.py | 262 | logger | info | logger.info( | Yes | No |  |
| priv/python/grpc_server.py | 274 | logger | info | logger.info( | Yes | No |  |
| priv/python/grpc_server.py | 281 | logger | debug | logger.debug("Heartbeat client disabled by configuration") | Yes | No |  |
| priv/python/grpc_server.py | 298 | logger | debug | logger.debug("Closing telemetry stream") | Yes | No |  |
| priv/python/grpc_server.py | 314 | logger | debug | logger.debug(f"Ping received: {request.message}") | Yes | No |  |
| priv/python/grpc_server.py | 333 | logger | info | logger.info(f"Proxying InitializeSession for: {request.session_id}") | Yes | No |  |
| priv/python/grpc_server.py | 347 | logger | info | logger.info(f"Proxying CleanupSession for: {request.session_id}") | Yes | No |  |
| priv/python/grpc_server.py | 363 | logger | debug | logger.debug(f"Proxying GetSession for: {request.session_id}") | Yes | No |  |
| priv/python/grpc_server.py | 377 | logger | debug | logger.debug(f"Proxying Heartbeat for: {request.session_id}") | Yes | No |  |
| priv/python/grpc_server.py | 392 | logger | info | logger.info(f"ExecuteTool: {request.tool_name} for session {request.session_id}") | Yes | No |  |
| priv/python/grpc_server.py | 412 | logger | debug | logger.debug(f"InitializeSession for {request.session_id}: {e}") | Yes | No |  |
| priv/python/grpc_server.py | 461 | logger | warning | logger.warning(f"Tool '{request.tool_name}' returned a generator but was called via non-streaming ExecuteTool. Returning empty result.") | Yes | No |  |
| priv/python/grpc_server.py | 494 | logger | error | logger.error(f"ExecuteTool failed: {e}", exc_info=True) | Yes | No |  |
| priv/python/grpc_server.py | 503 | logger | info | logger.info( | Yes | No |  |
| priv/python/grpc_server.py | 525 | logger | debug | logger.debug(f"InitializeSession for {request.session_id}: {e}") | Yes | No |  |
| priv/python/grpc_server.py | 528 | logger | info | logger.info(f"Creating SessionContext for {request.session_id}") | Yes | No |  |
| priv/python/grpc_server.py | 537 | logger | info | logger.info(f"Creating adapter instance: {self.adapter_class}") | Yes | No |  |
| priv/python/grpc_server.py | 669 | logger | error | logger.error( | Yes | No |  |
| priv/python/grpc_server.py | 681 | logger | error | logger.error(f"ExecuteStreamingTool failed: {e}", exc_info=True) | Yes | No |  |
| priv/python/grpc_server.py | 706 | logger | debug | logger.debug("StreamTelemetry stream opened") | Yes | No |  |
| priv/python/grpc_server.py | 714 | logger | debug | logger.debug("StreamTelemetry stream completed normally") | Yes | No |  |
| priv/python/grpc_server.py | 717 | logger | error | logger.error("StreamTelemetry stream error: %s", e, exc_info=True) | Yes | No |  |
| priv/python/grpc_server.py | 749 | logger | error | logger.error( | Yes | No |  |
| priv/python/grpc_server.py | 783 | logger | debug | logger.debug("Heartbeat loop started for session %s", session_id) | Yes | No |  |
| priv/python/grpc_server.py | 799 | logger | debug | logger.debug("Heartbeat loop stopped for session %s", session_id) | Yes | No |  |
| priv/python/grpc_server.py | 847 | logger | info | logger.info( | Yes | No |  |
| priv/python/grpc_server.py | 856 | logger | error | logger.error( | Yes | No |  |
| priv/python/grpc_server.py | 866 | logger | debug | logger.debug( | Yes | No |  |
| priv/python/grpc_server.py | 875 | logger | debug | logger.debug( | Yes | No |  |
| priv/python/grpc_server.py | 895 | logger | debug | logger.debug( | Yes | No |  |
| priv/python/grpc_server.py | 904 | logger | debug | logger.debug("Waiting for Elixir server before starting worker") | Yes | No |  |
| priv/python/grpc_server.py | 908 | logger | debug | logger.debug("wait_for_elixir_server returned %s", result) | Yes | No |  |
| priv/python/grpc_server.py | 911 | logger | error | logger.error(f"Cannot start Python worker: Elixir server at {elixir_address} is not available") | Yes | No |  |
| priv/python/grpc_server.py | 923 | logger | error | logger.error(f"Failed to import adapter {adapter_module}: {e}") | Yes | No |  |
| priv/python/grpc_server.py | 927 | logger | debug | logger.debug("Creating gRPC server") | Yes | No |  |
| priv/python/grpc_server.py | 937 | logger | debug | logger.debug("Creating bridge servicer") | Yes | No |  |
| priv/python/grpc_server.py | 953 | logger | debug | logger.debug("Binding to port %s", port) | Yes | No |  |
| priv/python/grpc_server.py | 958 | logger | debug | logger.debug("Bound to port %s", actual_port) | Yes | No |  |
| priv/python/grpc_server.py | 962 | logger | error | logger.error(error_msg) | Yes | No |  |
| priv/python/grpc_server.py | 966 | logger | exception | logger.exception(error_msg) | Yes | No |  |
| priv/python/grpc_server.py | 969 | logger | debug | logger.debug("Starting gRPC server") | Yes | No |  |
| priv/python/grpc_server.py | 973 | logger | debug | logger.debug("Server started; announcing readiness on port %s", actual_port) | Yes | No |  |
| priv/python/grpc_server.py | 976 | print | print | # CRITICAL: Use logger instead of print() for reliable capture via :stderr_to_stdout | Yes | No |  |
| priv/python/grpc_server.py | 977 | logger | info | logger.info(f"GRPC_READY:{actual_port}") | No (move to ready file) | Yes | Readiness signal |
| priv/python/grpc_server.py | 979 | logger | info | logger.info(f"gRPC server started on port {actual_port}") | Yes | No |  |
| priv/python/grpc_server.py | 980 | logger | info | logger.info(f"Connected to Elixir backend at {elixir_address}") | Yes | No |  |
| priv/python/grpc_server.py | 982 | logger | debug | logger.debug("Entering main event loop") | Yes | No |  |
| priv/python/grpc_server.py | 989 | logger | debug | logger.debug("Awaiting shutdown signal (SIGTERM/SIGINT)") | Yes | No |  |
| priv/python/grpc_server.py | 995 | logger | debug | logger.debug("Shutdown signal received; initiating graceful shutdown") | Yes | No |  |
| priv/python/grpc_server.py | 1002 | logger | debug | logger.debug("Closing servicer and stopping server") | Yes | No |  |
| priv/python/grpc_server.py | 1009 | logger | debug | logger.debug("Server stopped gracefully") | Yes | No |  |
| priv/python/grpc_server.py | 1014 | logger | info | logger.info("Shutdown cancelled by parent (this is normal).") | Yes | No |  |
| priv/python/grpc_server.py | 1016 | logger | debug | logger.debug("serve_with_shutdown completed") | Yes | No |  |
| priv/python/grpc_server.py | 1117 | logger | warning | logger.warning( | Yes | No |  |
| priv/python/grpc_server.py | 1147 | logger | exception | logger.exception("Unhandled exception in main loop: %s", e) | Yes | No |  |
| priv/python/grpc_server.py | 1154 | logger | info | logger.info("Python worker exiting gracefully.") | Yes | No |  |
| priv/python/grpc_server_threaded.py | 60 | logger | info | logger.info("Loaded grpc_server_threaded.py from %s", __file__) | Yes | No |  |
| priv/python/grpc_server_threaded.py | 73 | logger | debug | logger.debug("Snakepit process group created") | Yes | No |  |
| priv/python/grpc_server_threaded.py | 76 | logger | warning | logger.warning("Failed to create process group: %s", exc) | Yes | No |  |
| priv/python/grpc_server_threaded.py | 147 | logger | warning | logger.warning( | Yes | No |  |
| priv/python/grpc_server_threaded.py | 187 | logger | info | logger.info(f"Initializing threaded servicer: max_workers={max_workers}, safety_checks={enable_safety_checks}") | Yes | No |  |
| priv/python/grpc_server_threaded.py | 215 | logger | info | logger.info(f"✅ Threaded servicer initialized. Ready for concurrent requests.") | Yes | No |  |
| priv/python/grpc_server_threaded.py | 239 | logger | error | logger.error( | Yes | No |  |
| priv/python/grpc_server_threaded.py | 308 | logger | debug | logger.debug(f"[{threading.current_thread().name}] Proxying InitializeSession: {request.session_id}") | Yes | No |  |
| priv/python/grpc_server_threaded.py | 321 | logger | debug | logger.debug(f"[{threading.current_thread().name}] Proxying CleanupSession: {request.session_id}") | Yes | No |  |
| priv/python/grpc_server_threaded.py | 333 | logger | debug | logger.debug(f"[{threading.current_thread().name}] Proxying GetSession: {request.session_id}") | Yes | No |  |
| priv/python/grpc_server_threaded.py | 373 | logger | info | logger.info( | Yes | No |  |
| priv/python/grpc_server_threaded.py | 387 | logger | debug | logger.debug(f"InitializeSession: {e}") | Yes | No |  |
| priv/python/grpc_server_threaded.py | 458 | logger | info | logger.info( | Yes | No |  |
| priv/python/grpc_server_threaded.py | 466 | logger | error | logger.error(f"[{thread_name}] ExecuteTool #{request_id} failed: {e}", exc_info=True) | Yes | No |  |
| priv/python/grpc_server_threaded.py | 495 | logger | info | logger.info( | Yes | No |  |
| priv/python/grpc_server_threaded.py | 508 | logger | debug | logger.debug(f"InitializeSession: {e}") | Yes | No |  |
| priv/python/grpc_server_threaded.py | 646 | logger | error | logger.error( | Yes | No |  |
| priv/python/grpc_server_threaded.py | 661 | logger | error | logger.error(f"[{thread_name}] ExecuteStreamingTool #{request_id} failed: {e}", exc_info=True) | Yes | No |  |
| priv/python/grpc_server_threaded.py | 685 | logger | info | logger.info(f"✅ Connected to Elixir server at {elixir_address} after {attempt} attempt(s)") | Yes | No |  |
| priv/python/grpc_server_threaded.py | 689 | logger | debug | logger.debug(f"Elixir server not ready (attempt {attempt}/{max_retries}), retrying in {delay:.2f}s...") | Yes | No |  |
| priv/python/grpc_server_threaded.py | 693 | logger | error | logger.error(f"❌ Failed to connect to Elixir server after {max_retries} attempts") | Yes | No |  |
| priv/python/grpc_server_threaded.py | 707 | logger | info | logger.info(f"🚀 Starting threaded gRPC server: port={port}, max_workers={max_workers}") | Yes | No |  |
| priv/python/grpc_server_threaded.py | 711 | logger | error | logger.error("Cannot start: Elixir server unavailable") | Yes | No |  |
| priv/python/grpc_server_threaded.py | 723 | logger | error | logger.error(f"Failed to import adapter {adapter_module}: {e}") | Yes | No |  |
| priv/python/grpc_server_threaded.py | 754 | logger | error | logger.error(f"Failed to bind to port {port}") | Yes | No |  |
| priv/python/grpc_server_threaded.py | 757 | logger | error | logger.error(f"Exception binding to port {port}: {e}") | Yes | No |  |
| priv/python/grpc_server_threaded.py | 763 | logger | info | logger.info(f"GRPC_READY:{actual_port}") | No (move to ready file) | Yes | Readiness signal |
| priv/python/grpc_server_threaded.py | 764 | logger | info | logger.info(f"✅ Threaded gRPC server ready on port {actual_port} with {max_workers} worker threads") | Yes | No |  |
| priv/python/grpc_server_threaded.py | 771 | logger | info | logger.info("Shutdown signal received") | Yes | No |  |
| priv/python/grpc_server_threaded.py | 776 | logger | info | logger.info("Server stopped gracefully") | Yes | No |  |
| priv/python/grpc_server_threaded.py | 817 | logger | error | logger.error(f"Unhandled exception: {type(e).__name__}: {e}") | Yes | No |  |
| priv/python/snakepit_bridge/adapters/template.py | 44 | logger | info | logger.info(f"Session context set: {session_context.session_id}") | Yes | No |  |
| priv/python/snakepit_bridge/adapters/template.py | 57 | logger | info | logger.info(f"Adapter initialized for session: {self.session_context.session_id}") | Yes | No |  |
| priv/python/snakepit_bridge/adapters/template.py | 59 | logger | info | logger.info("Adapter initialized") | Yes | No |  |
| priv/python/snakepit_bridge/adapters/template.py | 68 | logger | info | logger.info(f"Cleaning up adapter for session: {self.session_context.session_id}") | Yes | No |  |
| priv/python/snakepit_bridge/adapters/threaded_showcase.py | 44 | logger | warning | logger.warning("NumPy not available. Some operations will use fallbacks.") | Yes | No |  |
| priv/python/snakepit_bridge/adapters/threaded_showcase.py | 98 | logger | info | logger.info(f"✅ {self.__class__.__name__} initialized (thread-safe mode)") | Yes | No |  |
| priv/python/snakepit_bridge/adapters/threaded_showcase.py | 158 | logger | debug | logger.debug(f"[{thread_name}] Cache hit for {cache_key[:8]}") | Yes | No |  |
| priv/python/snakepit_bridge/adapters/threaded_showcase.py | 435 | logger | info | logger.info(f"Initializing {self.__class__.__name__} in thread {threading.current_thread().name}") | Yes | No |  |
| priv/python/snakepit_bridge/base_adapter.py | 190 | logger | warning | logger.warning(f"No tools found in adapter {self.__class__.__name__}") | Yes | No |  |
| priv/python/snakepit_bridge/base_adapter.py | 204 | logger | info | logger.info(f"Registered {len(tools)} tools for session {session_id}") | Yes | No |  |
| priv/python/snakepit_bridge/base_adapter.py | 209 | logger | info | logger.info( | Yes | No |  |
| priv/python/snakepit_bridge/base_adapter.py | 215 | logger | error | logger.error(f"Failed to register tools: {response.error_message}") | Yes | No |  |
| priv/python/snakepit_bridge/base_adapter.py | 218 | logger | error | logger.error(f"Error registering tools: {e}") | Yes | No |  |
| priv/python/snakepit_bridge/base_adapter.py | 238 | logger | warning | logger.warning(f"No tools found in adapter {self.__class__.__name__}") | Yes | No |  |
| priv/python/snakepit_bridge/base_adapter.py | 252 | logger | info | logger.info(f"Registered {len(tools)} tools for session {session_id}") | Yes | No |  |
| priv/python/snakepit_bridge/base_adapter.py | 257 | logger | info | logger.info( | Yes | No |  |
| priv/python/snakepit_bridge/base_adapter.py | 263 | logger | error | logger.error(f"Failed to register tools: {response.error_message}") | Yes | No |  |
| priv/python/snakepit_bridge/base_adapter.py | 266 | logger | error | logger.error(f"Error registering tools (async): {e}") | Yes | No |  |
| priv/python/snakepit_bridge/base_adapter_threaded.py | 151 | logger | debug | logger.debug(f"[{thread_name}] Request #{request_id} starting: {func.__name__}") | Yes | No |  |
| priv/python/snakepit_bridge/base_adapter_threaded.py | 156 | logger | debug | logger.debug(f"[{thread_name}] Request #{request_id} completed in {duration:.3f}s") | Yes | No |  |
| priv/python/snakepit_bridge/base_adapter_threaded.py | 161 | logger | error | logger.error( | Yes | No |  |
| priv/python/snakepit_bridge/base_adapter_threaded.py | 221 | logger | debug | logger.debug(f"Initialized thread-safe adapter: {self.__class__.__name__}") | Yes | No |  |
| priv/python/snakepit_bridge/base_adapter_threaded.py | 398 | logger | debug | logger.debug(f"Cache hit for {input_data}") | Yes | No |  |
| priv/python/snakepit_bridge/session_context.py | 56 | logger | debug | logger.debug(f"SessionContext created for session {session_id}") | Yes | No |  |
| priv/python/snakepit_bridge/session_context.py | 90 | logger | info | logger.info(f"Loaded {len(tools)} Elixir tools for session {self.session_id}") | Yes | No |  |
| priv/python/snakepit_bridge/session_context.py | 94 | logger | warning | logger.warning(f"Failed to load Elixir tools: {e}") | Yes | No |  |
| priv/python/snakepit_bridge/session_context.py | 168 | logger | error | logger.error(f"Error calling Elixir tool '{tool_name}': {e}") | Yes | No |  |
| priv/python/snakepit_bridge/session_context.py | 181 | logger | debug | logger.debug(f"Session {self.session_id} cleaned up") | Yes | No |  |
| priv/python/snakepit_bridge/session_context.py | 183 | logger | debug | logger.debug(f"Session cleanup failed (best effort): {e}") | Yes | No |  |
| priv/python/snakepit_bridge/telemetry/backends/stderr.py | 50 | syswrite | stderr.write | sys.stderr.write(f"TELEMETRY:{json.dumps(payload)}\n") | Yes | Yes | Telemetry stderr backend |
| priv/python/snakepit_bridge/telemetry/backends/stderr.py | 54 | syswrite | stderr.write | sys.stderr.write(f"TELEMETRY_ERROR: {e}\n") | Yes | Yes | Telemetry stderr backend |
| priv/python/snakepit_bridge/thread_safety_checker.py | 26 | print | print | print(checker.get_report()) | Yes | No |  |
| priv/python/snakepit_bridge/thread_safety_checker.py | 148 | logger | warning | logger.warning(msg) | Yes | No |  |
| priv/python/snakepit_bridge/thread_safety_checker.py | 184 | logger | warning | logger.warning(msg) | Yes | No |  |
| priv/python/snakepit_bridge/thread_safety_checker.py | 292 | logger | info | logger.info("Thread Safety Check Report:") | Yes | No |  |
| priv/python/snakepit_bridge/thread_safety_checker.py | 293 | logger | info | logger.info(f"  Total methods tracked: {report['total_methods_tracked']}") | Yes | No |  |
| priv/python/snakepit_bridge/thread_safety_checker.py | 294 | logger | info | logger.info(f"  Concurrent accesses: {len(report['concurrent_accesses'])}") | Yes | No |  |
| priv/python/snakepit_bridge/thread_safety_checker.py | 295 | logger | info | logger.info(f"  Warnings issued: {report['warnings_issued']}") | Yes | No |  |
| priv/python/snakepit_bridge/thread_safety_checker.py | 297 | logger | info | logger.info(f"  {rec}") | Yes | No |  |
| priv/python/snakepit_bridge/thread_safety_checker.py | 309 | logger | info | logger.info("Thread safety checking enabled" + (" (strict mode)" if strict_mode else "")) | Yes | No |  |
| priv/python/snakepit_bridge/thread_safety_checker.py | 316 | logger | info | logger.info("Thread safety checking disabled") | Yes | No |  |
| priv/python/snakepit_bridge/thread_safety_checker.py | 456 | print | print | print("\n" + "="*70) | Yes | No |  |
| priv/python/snakepit_bridge/thread_safety_checker.py | 457 | print | print | print("Thread Safety Analysis Report") | Yes | No |  |
| priv/python/snakepit_bridge/thread_safety_checker.py | 458 | print | print | print("="*70) | Yes | No |  |
| priv/python/snakepit_bridge/thread_safety_checker.py | 460 | print | print | print(f"\nExecution Summary:") | Yes | No |  |
| priv/python/snakepit_bridge/thread_safety_checker.py | 461 | print | print | print(f"  Total Runtime: {report['total_runtime']:.2f}s") | Yes | No |  |
| priv/python/snakepit_bridge/thread_safety_checker.py | 462 | print | print | print(f"  Threads Detected: {report['total_threads_seen']}") | Yes | No |  |
| priv/python/snakepit_bridge/thread_safety_checker.py | 463 | print | print | print(f"  Methods Tracked: {report['total_methods_tracked']}") | Yes | No |  |
| priv/python/snakepit_bridge/thread_safety_checker.py | 464 | print | print | print(f"  Warnings Issued: {report['warnings_issued']}") | Yes | No |  |
| priv/python/snakepit_bridge/thread_safety_checker.py | 467 | print | print | print(f"\nConcurrent Accesses Detected:") | Yes | No |  |
| priv/python/snakepit_bridge/thread_safety_checker.py | 469 | print | print | print(f"  - {method}: {count} threads") | Yes | No |  |
| priv/python/snakepit_bridge/thread_safety_checker.py | 472 | print | print | print(f"\nRecommendations:") | Yes | No |  |
| priv/python/snakepit_bridge/thread_safety_checker.py | 474 | print | print | print(f"  {rec}") | Yes | No |  |
| priv/python/snakepit_bridge/thread_safety_checker.py | 476 | print | print | print("\n" + "="*70 + "\n") | Yes | No |  |
| priv/python/tests/test_orjson_integration.py | 89 | print | print | print(f"\nRaw JSON benchmark:") | Yes | No |  |
| priv/python/tests/test_orjson_integration.py | 90 | print | print | print(f"  stdlib json: {json_time:.4f}s") | Yes | No |  |
| priv/python/tests/test_orjson_integration.py | 91 | print | print | print(f"  orjson:      {orjson_time:.4f}s") | Yes | No |  |
| priv/python/tests/test_orjson_integration.py | 92 | print | print | print(f"  speedup:     {speedup:.2f}x") | Yes | No |  |
| priv/python/tests/test_orjson_integration.py | 131 | print | print | print(f"\nTypeSerializer small payload benchmark:") | Yes | No |  |
| priv/python/tests/test_orjson_integration.py | 132 | print | print | print(f"  baseline (protobuf + json): {baseline_time:.4f}s") | Yes | No |  |
| priv/python/tests/test_orjson_integration.py | 133 | print | print | print(f"  orjson (protobuf + orjson): {typeserializer_time:.4f}s") | Yes | No |  |
| priv/python/tests/test_orjson_integration.py | 134 | print | print | print(f"  speedup:                     {speedup:.2f}x") | Yes | No |  |
| priv/python/tests/test_orjson_integration.py | 181 | print | print | print(f"\nTypeSerializer large payload benchmark:") | Yes | No |  |
| priv/python/tests/test_orjson_integration.py | 182 | print | print | print(f"  baseline (protobuf + json): {baseline_time:.4f}s") | Yes | No |  |
| priv/python/tests/test_orjson_integration.py | 183 | print | print | print(f"  orjson (protobuf + orjson): {typeserializer_time:.4f}s") | Yes | No |  |
| priv/python/tests/test_orjson_integration.py | 184 | print | print | print(f"  speedup:                     {speedup:.2f}x") | Yes | No |  |
| priv/python/tests/test_telemetry.py | 71 | logger | info | logger.info("no correlation context") | Yes | No |  |
| priv/python/tests/test_telemetry.py | 77 | logger | info | logger.info("context set") | Yes | No |  |
