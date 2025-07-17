# Snakepit Examples

## Basic Adapter Examples

- **`generic_demo_python.exs`** - Python adapter demonstration with compute operations
- **`generic_demo_javascript.exs`** - JavaScript adapter demonstration with extended features

## Advanced DSPy Examples

The main examples have been moved to `snakepit_dspy/examples/` which demonstrate real-world usage with DSPy integration.

See `../snakepit_dspy/examples/` for:

- **`simple_qa_bypass_demo.exs`** - Direct Q&A with single worker
- **`simple_signature_demo.exs`** - Direct signature-based code review  
- **`pooled_qa_demo.exs`** - Pooled Q&A with load balancing
- **`pooled_signature_demo.exs`** - Pooled signatures with real LLM calls

These examples show real Gemini API integration through DSPy with actual language model responses.

## Usage

### Basic Adapter Demos

```bash
# Test Python adapter functionality
elixir examples/generic_demo_python.exs

# Test JavaScript adapter functionality  
elixir examples/generic_demo_javascript.exs
```

### Advanced DSPy Demos

```bash
cd ../snakepit_dspy
elixir examples/simple_qa_bypass_demo.exs
elixir examples/pooled_qa_demo.exs
```

**Prerequisites**: Set `GEMINI_API_KEY` environment variable.