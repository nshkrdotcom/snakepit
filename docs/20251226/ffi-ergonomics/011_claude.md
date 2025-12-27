Looking at the full picture now, the architecture is well-aligned. Snakepit handles the hard runtime problems (pooling, crash isolation, gRPC, session affinity) while SnakeBridge handles the compile-time generation. The 0.7.5 additions (`PythonPackages`, structured exceptions, crash barrier, zero-copy stubs) close most of the critical gaps from the integration plan.

**What's working well:**

The runtime contract in `README_GRPC.md` (`kwargs`, `call_type`, `idempotent`, `payload_version`) is exactly what you need for the Handle pattern from the earlier FFI discussion. The pieces are there:

```elixir
# This already works with current architecture:
payload = %{
  "call_type" => "method",
  "ref" => handle.id,
  "method" => "__add__",
  "args" => [other_handle],
  "kwargs" => %{},
  "idempotent" => false
}
Snakepit.execute("snakebridge.call", payload)
```

The crash barrier with tainting is the right answer to "ML libraries crash constantly." The session affinity gives you the worker pinning needed for stateful object handles.

**The ergonomics gap:**

The Handle pattern works, but using it directly is verbose. The earlier conversation identified three solutions:

1. **Helper Packs** - Python-side convenience wrappers (your "Option #2")
2. **Generated ergonomic wrappers** - SnakeBridge could generate higher-level APIs
3. **Inline drops** (~PY sigil) - for complex orchestration that shouldn't cross the wire repeatedly

SnakeBridge currently generates thin wrappers. For the SymPy case, you'd want either:

```elixir
# Generated from a "helper pack" that SnakeBridge discovers:
SymPy.parse_implicit("2x")  # Calls Python helper that binds transformations
```

Or a more sophisticated generator that understands common patterns and emits ergonomic code.

**Zero-copy status:**

`Snakepit.ZeroCopyRef` exists with DLPack/Arrow stubs and fallback telemetry. The architecture is right (shared memory segments, handles not data), but the actual implementation for real tensors isn't there yet. This is the biggest gap for ML credibility.

**What I'd prioritize next:**

1. **Finish zero-copy for at least NumPy arrays** - mmap-based shared memory, not pickle/JSON. This is the "quiet talk" feature.

2. **Helper pack discovery in SnakeBridge** - Let SnakeBridge find `priv/python/helpers/*.py` and generate wrappers that call those instead of raw library functions. This solves the SymPy problem without transpilation.

3. **The ~PY sigil** - For cases where you need to compose multiple Python operations, sending a code block is cleaner than N round-trips:

```elixir
result = SnakeBridge.run ~PY"""
from sympy.parsing.sympy_parser import parse_expr, standard_transformations, implicit_multiplication_application
transforms = standard_transformations + (implicit_multiplication_application,)
return parse_expr('#{expr}', transformations=transforms)
"""
```

**One thing to watch:**

The docs mention both `lib/snakebridge_generated/` and `_build/snakebridge/` in different places. The integration plan correctly identifies this as an inconsistency. Stick with generated source in `lib/` - it's simpler, works with all tooling, and the determinism strategy in `05-determinism-strategy.md` already addresses the stability requirements.

The architecture is solid. The main work is filling in the ergonomic layer and finishing zero-copy.
