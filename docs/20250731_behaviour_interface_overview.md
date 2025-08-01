# `Snakepit.Adapter` Behaviour: An Architectural Overview

- **Date**: 2025-07-31
- **Status**: Draft

## 1. Executive Summary

This document provides a high-level overview of the `Snakepit.Adapter` behaviour, the cornerstone of the `snakepit` process management ecosystem. The adapter behaviour defines a formal contract, creating a "perfect seam" that decouples the generic **Infrastructure** (`snakepit`) from any specific **Runtime** (e.g., a Python gRPC server, a Ruby script, etc.).

Understanding this architecture is the first step to integrating a new language or communication protocol with the `snakepit` engine.

## 2. The Core Problem: Managing External Processes

Reliably managing external OS processes from within the BEAM (the Erlang virtual machine) presents several challenges:

-   **Orphaned Processes**: If the main Elixir application crashes, the external OS processes it started can be left running as "orphans," consuming system resources.
-   **Startup Race Conditions**: It's difficult to know exactly when an external process has finished initializing and is ready to accept requests. Relying on fixed timers (e.g., `Process.sleep(5000)`) is a common but brittle solution that leads to intermittent failures.
-   **Tangled Logic**: Without a clean separation, the logic for managing process lifecycles becomes entangled with the logic for communicating with those processes (e.g., gRPC details, JSON serialization), making the system hard to maintain, test, and extend.

## 3. The Solution: The `Snakepit.Adapter` Behaviour

The `Snakepit.Adapter` behaviour solves these problems by formalizing the separation of concerns. It's an Elixir "interface" that defines a contract between two distinct components:

-   **`snakepit` (The Engine)**: Its only job is to be a best-in-class OS process manager. It knows how to start, stop, and supervise workers, but it knows nothing about *what* they are or *how* to talk to them.
-   **The Adapter (The Implementation)**: Its only job is to be a runtime expert. It encapsulates all the specific knowledge required to manage a particular type of worker, such as a Python process communicating over gRPC.

This design allows the `snakepit` engine to be completely agnostic of the worker's language, environment, or communication protocol.

## 4. Design Principles

The architecture is guided by a few key software design principles:

-   **Single Responsibility Principle (SRP)**: `snakepit` manages processes. The adapter manages communication. Each has one, clearly defined job.
-   **Dependency Inversion Principle (DIP)**: The high-level `snakepit` engine does not depend on low-level runtimes (like Python). Instead, both depend on the `Snakepit.Adapter` abstraction.
-   **Protocol Agnosticism**: `snakepit` has zero knowledge of gRPC, HTTP, MessagePack, or any other communication protocol. This logic is entirely hidden inside the adapter.
-   **Deterministic Synchronization**: The system **forbids** using timers or `sleep` calls to coordinate process startup. Readiness must be confirmed via an explicit signal from the worker process.

## 5. The Contract: A Summary of Responsibilities

The `Snakepit.Adapter` behaviour is a contract. Here is what each party promises to do:

### What `snakepit` (The Engine) Promises:

1.  **To Manage the Lifecycle**: It will call your adapter's functions (`init`, `start_worker`, `terminate`) at the appropriate times.
2.  **To Supervise**: It will automatically restart a worker by calling `start_worker` again if its supervising Elixir process crashes.
3.  **To Track OS Processes**: It will take the OS Process ID (PID) you provide from `start_worker` and monitor it.
4.  **To Prevent Orphans**: On application startup, it will use its process registry to find and terminate any orphaned processes from a previous, unclean shutdown.

### What the Adapter (The Implementation) Promises:

1.  **To Implement the Behaviour**: You must provide a concrete implementation for all callbacks defined in the `Snakepit.Adapter` behaviour.
2.  **To Return the OS PID**: Your `start_worker` implementation **must** spawn an external process and return its true OS-level PID. This is a non-negotiable part of the contract.
3.  **To Implement Deterministic Startup**: Your `start_worker` function must not return `:ok` until the external process is fully initialized and ready. This must be achieved by waiting for a signal from the worker (e.g., a specific message on STDOUT).
4.  **To Manage Communication**: You are responsible for all protocol-specific logic (e.g., gRPC connection management, message serialization).
5.  **To Manage the Environment**: You are responsible for all language-specific concerns, such as using the correct Python virtual environment (`venv`).

## 6. Next Steps

Now that you understand the high-level architecture, you can proceed to the following documents:

-   **[`docs/20250731_implementing_an_adapter.md`](./20250731_implementing_an_adapter.md)**: A detailed, step-by-step guide on how to build your own adapter.
-   **[`docs/20250731_python_client_guide.md`](./20250731_python_client_guide.md)**: A guide for developers writing Python worker scripts that need to communicate back to the Elixir host.
