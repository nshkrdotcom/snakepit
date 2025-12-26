# 05 - Runtime Contract: SnakeBridge -> Snakepit

## Purpose

Define the exact payload schema used by SnakeBridge-generated wrappers when calling Snakepit.

## Tool Names

- `snakebridge.call` (request/response)
- `snakebridge.stream` (streaming)

## Base Payload

```json
{
  "library": "numpy",
  "python_module": "numpy.linalg",
  "function": "solve",
  "args": ["..."],
  "kwargs": {"axis": 0},
  "idempotent": true
}
```

### Fields

- `library`: top-level library name
- `python_module`: dotted module path for submodules
- `function`: function/method name
- `args`: positional args (may include ZeroCopyRef handles)
- `kwargs`: keyword args
- `idempotent`: used by crash barrier retry logic

## Class/Method Payloads

```json
{
  "call_type": "class",
  "library": "sympy",
  "python_module": "sympy",
  "class": "Symbol",
  "function": "__init__",
  "args": ["x"],
  "kwargs": {}
}
```

```json
{
  "call_type": "method",
  "library": "sympy",
  "python_module": "sympy",
  "instance": "<pyref>",
  "function": "simplify",
  "args": [],
  "kwargs": {}
}
```

```json
{
  "call_type": "get_attr",
  "library": "sympy",
  "python_module": "sympy",
  "instance": "<pyref>",
  "attr": "name"
}
```

## Streaming Payloads

Streaming uses the same payload but routed to `snakebridge.stream` and returns chunked results.

## Versioning

The payload schema is versioned in the adapter. If the schema changes, increment a `payload_version` field and update `snakebridge.lock` with adapter hash.

