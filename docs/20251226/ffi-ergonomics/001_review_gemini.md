That is a **half-truth** that often confuses developers building bridges like `snakebridge`.

The short answer is: You **can** serialize data (strings, numbers, lists, maps) over the wire easily. You **cannot** easily serialize "live" Python behavior (functions, classes, open file handles, library objects) from Elixir to Python.

Here is the breakdown of why this happens, why `pickle` is likely a trap for your specific problem, and why your design document actually has the right solution already.

### 1. The Serialization "Wall"

In FFI (Foreign Function Interface), there is a strict boundary between Elixir and Python.

* **Pass by Value (Works):** You send the string `"2x"`. The bridge turns this into bytes (JSON, Erlang Term Format, or MsgPack), sends it over the wire, and Python reconstructs the string `"2x"`.
* **Pass by Behavior (Fails):** You want to send `implicit_multiplication_application`. This is not data; it is a Python function in memory. Elixir cannot "send" this function because Elixir doesn't know what that function contains—it only exists inside the Python VM.

### 2. Is `pickle` the answer?

You asked about `pickle` and the Elixir port of it.

* **What it is:** `pickle` is Python’s native format for serializing Python objects structures to bytes.
* **The Elixir Port:** The Elixir pickle library allows Elixir to read/write these byte streams.
* **Why it probably won't help you:** To pass the `implicit_multiplication_application` function using pickle, you would have to construct a valid Python pickle byte-stream **inside Elixir** that represents that complex SymPy function. This is incredibly difficult, brittle, and essentially requires re-implementing Python's internal logic inside Elixir.

**The Pickle Trap:** Even if you pickle a function reference, `pickle` often just saves the *name* of the function (`sympy.parsing.implicit...`) and expects the receiving end to import it. If you are just sending the name, you don't need pickle—you can just send a string and have your helper resolve it.

### 3. The Real Problem (As identified in your Doc)

Your design document hits the nail on the head in the **"Concrete Example"** section.

The problem isn't that you can't serialize; it's that the API requires a **Runtime Reference**.

```python
# The argument 'transformations' expects a list of LIVE Python objects
parse_expr("2x", transformations=(standard_transformations + (implicit_multiplication_application,)))

```

You cannot serialize `implicit_multiplication_application` because it's not a value you created; it's a reference to code living in the Python library.

### 4. The Solution: "Handles" not "Serials"

Your document suggests **Pattern #1 (Python Helper Module)** and **Pattern #5 (Object Reference Model)**. These are the correct industry-standard ways to solve this.

Instead of trying to serialize the object over the wire, you serialize a **Handle** (a name or an ID) or use a **Helper**.

#### Approach A: The Helper (Best for now)

As your doc suggests, keep the complexity in Python.
**Elixir sends:**

```elixir
SnakeBridge.call("my_helper_module", "parse_implicit", ["2x"])

```

**Python (Helper):**

```python
def parse_implicit(expr):
    # Python resolves the complex objects locally
    t = standard_transformations + (implicit_multiplication_application,)
    return parse_expr(expr, transformations=t)

```

*Why this wins:* You only send simple strings (data) over the wire.

#### Approach B: The Registry (The "Advanced" fix)

If you want to stay generic, you map strings to objects in Python.
**Elixir sends:**

```elixir
# We send a "token" or "flag" representing the object
SnakeBridge.call("sympy", "parse_expr", ["2x"], kwargs: %{transformations: :implicit_multiplication})

```

**Python (Shim):**

```python
def call(func, args, kwargs):
    if kwargs.get('transformations') == 'implicit_multiplication':
        kwargs['transformations'] = ... # Load actual object here
    return func(*args, **kwargs)

```

### Summary

* **Serialization is for Data:** You can already do this.
* **Pickle is risky:** Don't use it to bridge logic. It introduces security risks and high complexity for little gain in this specific context.
* **Your Doc is Correct:** The section on "Non-Serializable Inputs" is accurate. The fix is not a better serialization format; the fix is an **architectural pattern** (Helpers or Registries) that keeps complex object creation on the Python side of the wall.

**Next Step:** Would you like to draft the Python "Helper Pack" module for SymPy based on your Option #2 to see how the Elixir-side API would look?
