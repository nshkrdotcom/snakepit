# SnakeBridge/Snakepit FFI Ergonomics

Date: 2025-12-26  
Status: Discussion  
Owner: SnakeBridge/Snakepit core

## Summary

Calling Python from Elixir over a process boundary is powerful, but small gaps in
API semantics and type behavior can force users to write one-off helpers. This
doc frames the ergonomics problem, explains why it happens (using concrete
examples like SymPy implicit multiplication), and lays out patterns that make
the FFI feel native without sacrificing safety or debuggability.

This document is self-contained and can be used as a starting point for deeper
research on FFI ergonomics and bridge design.

## Problem Statement

The current bridge exposes Python modules/functions through Elixir wrappers.
This is usually enough, but breaks down when:

- Python APIs require non-serializable objects or configuration objects
  (ex: SymPy parser transformations).
- "Implicit" Python behaviors are not explicit in a remote call.
- Python expects stateful or contextful usage patterns.

When that happens, users end up writing helper modules in Python to bridge the
gap. If that is too frequent, the FFI feels "leaky" and hard to use.

## Concrete Example: SymPy Implicit Multiplication

SymPy's `parse_expr` supports implicit multiplication like "2x" only when a
transformation object is provided:

```
parse_expr("2x", transformations=(standard_transformations +
                                  (implicit_multiplication_application,)))
```

The transformation object is a Python-side object, not serializable across the
Elixir/Python boundary. A pure "call a function with args" API cannot express
this configuration. The smallest workable fix is a Python helper function that
pre-binds the transformation. That helper is not a failure; it is a symptom of
the mismatch between:

- A remote call interface that accepts only serializable data, and
- A local API that expects "call-time" access to complex objects.

## Ergonomics Goals

1. **Minimize one-off wrappers** for common Python idioms.
2. **Keep the remote call model explicit**, so errors are diagnosable.
3. **Preserve safe defaults**: avoid arbitrary code execution by default.
4. **Make escape hatches obvious** when advanced usage is needed.
5. **Avoid surprising semantics**: what works in Python should feel similar
   in Elixir, or be clearly documented when not.

## Why FFI Ergonomics Are Hard

### 1) Serialization Boundaries

Only data can cross the boundary. Objects, closures, and runtime configuration
cannot unless explicitly represented.

### 2) Implicit Behavior vs. Explicit Calls

Python libraries often rely on implicit state (global config, module state,
thread-locals). A remote call model makes those implicit dependencies invisible
unless first-classed.

### 3) Stateful Objects

Many Python APIs are object-oriented and stateful. Remote calls need a stable
object reference, lifecycle management, and cleanup semantics.

### 4) Error Semantics

Python exceptions are rich and contextual. Without deliberate mapping, they
arrive as opaque strings.

### 5) Version Drift

Library APIs evolve. Introspection-driven bindings can drift from real behavior
if APIs change or require runtime configuration.

## Taxonomy of Ergonomic Gaps

### A) Non-Serializable Inputs

- Parser transformations
- Callables
- Class instances passed as params

### B) Context-Dependent Behavior

- Global configuration
- Environment variables
- Thread-local settings

### C) Implicit Conventions

- Python accepts implicit multiplication, Elixir does not.
- Python allows "duck typing" where Elixir expects explicit types.

### D) Object Lifecycle

- Construct -> call methods -> cleanup
- Remote references must be tracked and collected.

## Patterns to Improve Ergonomics

### 1) Python Helper Module (Today’s Minimal Escape Hatch)

Create a tiny Python module with pre-bound configuration. Example:

```
def parse_expr_implicit(expr):
    transformations = standard_transformations + (implicit_multiplication_application,)
    return parse_expr(expr, transformations=transformations)
```

Benefits:
- Small, explicit, local to the project.
- Works with current bridge semantics.

Limitations:
- Not discoverable by default.
- Easy to proliferate, harder to standardize.

### 2) Standard "Helper Pack"

Ship a curated Python helper module with SnakeBridge for common idioms:

- SymPy implicit parse
- NumPy safe array creation
- Pandas parsing utilities

Benefits:
- Reduces one-off wrapper churn.
- Consistent across projects.

Tradeoff:
- Adds maintenance burden for helper pack.

### 3) FFI Prelude/Registry

Allow registration of named Python objects and functions at startup:

- Prelude returns a stable name ("sympy_parse_implicit")
- Elixir calls by name instead of by module/function.

Benefits:
- Avoids one-off modules.
- Keeps configuration centralized and explicit.

### 4) Capabilities and Declarative Adapters

Add metadata that declares how a library should be called:

```
%Library{
  name: :sympy,
  helpers: [:parse_implicit],
  call_transform: :sympy_defaults
}
```

Benefits:
- Encodes usage semantics in configuration.
- Allows consistent generation of wrappers.

### 5) Object Reference Model with Lifecycle Hooks

Expose a structured, explicit reference model:

- `call_class` -> `call_method` -> `release`
- Reference IDs are scoped to a session
- Garbage-collection fallback on session end

Benefits:
- Makes stateful APIs usable without leaking.

### 6) Typed Wrapper Contracts (Optional)

A typed "contract layer" that documents expected types and conversions:

- Known input/output shapes
- Explicit conversions (ex: floats, decimals, arrays)
- Error mapping and suggested fixes

Benefits:
- Better developer experience
- More precise error messages

## Design Principles

1. **Explicitness beats magic**: prefer clear, named helpers to hidden behavior.
2. **Small steps first**: add a helper registry before introducing heavy DSLs.
3. **Make safe defaults boring**: new users should not see surprising behavior.
4. **Errors should teach**: include the Python error + suggestion when possible.
5. **Minimal surface area**: do not expose arbitrary execution by default.

## Proposed Roadmap (Ergonomics-Focused)

Short-term:
- Add a "helper pack" for common tasks (SymPy implicit parse).
- Document helper usage pattern in SnakeBridge examples.
- Improve error classification for missing helper functionality.

Mid-term:
- Implement a "helper registry" in the adapter to map helper names to callables.
- Support helper lookups from config (`helpers: ["sympy.parse_implicit"]`).

Long-term:
- Define an FFI contract layer for core libraries (SymPy, NumPy, Pandas).
- Introduce a stable schema to describe conversions and helpers.

## How to Evaluate Ergonomics

Metrics to track:

- Number of helper modules per project.
- Frequency of "missing function/attribute" errors.
- Time-to-first-working-call in example apps.
- Number of custom conversions required for common libraries.

Qualitative questions:

- Can a new user call common functions without reading internals?
- Are helper modules intentional and minimal?
- Are errors precise enough to guide fixes?

## Research Keywords (for deeper study)

These topics are useful for further research:

- "FFI ergonomics"
- "Remote object references"
- "Bridge protocol design"
- "SymPy parse_expr transformations"
- "Type mapping in cross-language FFI"
- "Serialization boundary design"
- "Python interpreter embedding vs remote"

## Open Questions

- Should helper modules be shipped in SnakeBridge or registered by users?
- How much of Python "implicit behavior" should be modeled in Elixir?
- What is the right balance between codegen and manual helpers?
- How should version drift be detected in helper-pack functions?

## Takeaways

Needing a helper for SymPy implicit parsing is not a failure of the bridge; it
is a classic FFI boundary issue. The path to better ergonomics is to formalize
helpers and configure them explicitly, not to hide the problem. If we standardize
helpers, document their use, and provide a helper registry, the bridge will feel
much more native without sacrificing correctness.
