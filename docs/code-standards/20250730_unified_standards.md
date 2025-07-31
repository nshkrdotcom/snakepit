# Snakepit Ecosystem: Code, Architecture, and Testing Standards

- **Date**: 2025-07-30
- **Status**: Proposed
- **Author**: Gemini Engineering Expert

## 1. Philosophy: The Three Pillars

All code contributed to the Snakepit ecosystem must adhere to three core principles. These are not guidelines; they are requirements for creating a professional, maintainable, and robust platform.

1.  **Clarity over Cleverness:** Code is read far more often than it is written. We prioritize clear, explicit, and easy-to-understand code over terse or overly "clever" solutions. If a piece of code requires a comment to explain *what* it is doing, it needs to be refactored.
2.  **Contracts over Concretions:** We build a modular system by programming to abstractions (behaviours), not to concrete implementations. This is the key to our testability and future flexibility.
3.  **Concurrency by Design:** We do not "add" concurrency later. We design our systems from the ground up using OTP principles to ensure they are concurrent, parallel, and fault-tolerant by nature.

## 2. Architectural Standards

### 2.1. The Four-Layer Model

The ecosystem is divided into four distinct layers. Code must never violate these boundaries.

1.  **Infrastructure (`snakepit`):** Pure, generic process management. Knows nothing of protocols or domains. Exposes the `Snakepit.Adapter` behaviour.
2.  **Runtime (`dspex_runtime_py`, etc.):** Implements the `Snakepit.Adapter`. Encapsulates all logic for a specific transport and language (e.g., Python over gRPC). Knows nothing of high-level concepts like "Tools" or "Sessions".
3.  **Platform (`dspex_platform`):** Provides the high-level, protocol-agnostic API for ML concepts (Tools, Sessions, Variables). Depends on a `Runtime` abstraction.
4.  **Consumer (`dspex`, `YourApp`):** The final user-facing application. Depends only on the `Platform` layer.

### 2.2. Configuration

- **Explicit over Implicit:** All configuration must be explicit and documented in `config.exs`. Avoid relying on application environment variables for complex configuration.
- **Compile-Time Validation:** Use structs or dedicated modules (e.g., `Snakepit.Config`) to validate configuration at compile time where possible.
- **Runtime Discovery is Forbidden:** A child module must never reach up and discover its parent or the wider system configuration. All necessary configuration must be passed down explicitly during initialization.

## 3. Elixir Code Standards

### 3.1. Formatting and Linting

- **`mix format` is Law:** All submitted code must be formatted using `mix format`. This is non-negotiable and will be checked by CI.
- **`mix credo --strict` must pass:** All code must pass Credo checks with the `--strict` flag. This enforces a high standard of code style and consistency.

### 3.2. Modules and Functions

- **Small Modules, Single Purpose:** Modules should be small and adhere to the Single Responsibility Principle.
- **Pattern Matching over Conditionals:** Prefer function head pattern matching to complex `case` or `cond` statements. This leads to clearer, more declarative code.
- **Explicit Imports:** Use `import` sparingly. Prefer to alias modules and call functions with their fully qualified name (e.g., `MyModule.my_function()`) to improve clarity.
- **Typespecs are Mandatory:** All public functions (`@spec`) and structs (`@type`) must have complete and accurate typespecs. This is checked by Dialyzer.
- **`@doc` for all Public Functions:** All public functions must have documentation that clearly explains their purpose, parameters, and return values. Include at least one `@doc """..."""` example.

### 3.3. OTP and Concurrency

- **GenServers are for State:** Use a `GenServer` only when you need to manage and serialize access to state. For purely concurrent work, use `Task`.
- **Name Processes Explicitly:** When starting a process that needs to be referenced, register it with a name using `{:via, Registry, {MyRegistry, name}}`. Avoid passing PIDs around.
- **Supervision Strategy:** Always define an explicit supervision strategy. Do not rely on the default `:one_for_one`. Think carefully about whether a worker crash should affect its siblings.

## 4. Testing Standards (Absorbing `test-architecture-supertester.md`)

This section formalizes and expands upon the excellent foundation in the original testing document.

### 4.1. Core Testing Principles

1.  **Zero `Process.sleep`:** All synchronization must be deterministic. Use message passing, process monitoring, or libraries like `Supertester` to wait for events.
2.  **Full Isolation (`async: true`):** All tests must be able to run concurrently without conflicts. This is the default. Any test marked `async: false` requires a strong justification.
3.  **Test the Contract, Not the Implementation:** Tests should focus on the public API and behaviour of a module, not its internal state.
4.  **The Test is Documentation:** A test file should serve as a clear example of how to use the module it is testing.

### 4.2. Test Directory Structure

We will adopt the proposed structure, as it provides excellent separation of concerns:

```
test/
├── unit/           # Isolated component tests (mocking dependencies).
├── integration/    # Tests for interaction between components within the same app.
├── contract/       # Tests that verify an implementation adheres to a behaviour (e.g., an Adapter test).
├── performance/    # Load and benchmark tests (optional, not run in CI).
├── chaos/          # Resilience and fault-tolerance testing.
└── support/        # Test helpers, factories, and mock implementations.
```

### 4.3. The Test Case Foundation

All test files will use a project-specific `TestCase` module that sets up the testing foundation.

```elixir
# test/support/my_app_case.ex
defmodule MyApp.TestCase do
  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case, async: true
      # We can integrate Supertester or other helpers here.

      # Common setup logic for all tests.
      setup do
        # E.g., start a mock registry.
        :ok
      end
    end
  end
end
```

### 4.4. Mocking and Boundaries

- **Mock with Behaviours:** The primary way to mock a dependency is by creating a mock implementation of its behaviour. For example, to test a module that uses a `Snakepit.Adapter`, you would create a `MockAdapter` and pass it during initialization.
- **Do Not Use Mocking Libraries:** Avoid libraries that perform runtime monkey-patching or modification of modules. This is an anti-pattern that leads to brittle tests. Use explicit dependency injection of mock behaviours instead.

### 4.5. Chaos and Fault-Tolerance Testing

For critical infrastructure like `snakepit`, chaos testing is not optional.

- **Supervision Recovery:** Write explicit tests that kill worker processes and assert that the supervisor correctly restarts them according to its strategy.
- **Process Leaks:** Write tests that simulate a crash of the main application and verify that the `ApplicationCleanup` logic successfully terminates all orphaned OS processes.

## 5. Python Code Standards

For Python code living within a Runtime's `priv/python` directory:

- **Formatting:** Use `black` for all Python code.
- **Linting:** Use `flake8` or `ruff` to enforce code quality.
- **Typing:** All new Python code should use modern type hints (`typing` module).
- **Dependencies:** All dependencies must be explicitly listed in `requirements.txt`.
- **The Python code is a service:** It should be stateless. All state must be managed by the Elixir host and passed in during a request.

## 6. CI/CD Pipeline Requirements

The CI pipeline will be the ultimate enforcer of these standards. A pull request cannot be merged unless the following checks pass:

1.  `mix format --check-formatted`
2.  `mix credo --strict`
3.  `mix dialyzer`
4.  `mix test` (all test suites, except performance)
5.  (For Runtimes) Python linter and formatter checks.
