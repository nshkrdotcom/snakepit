# Snakepit Examples

The main examples have been moved to `snakepit_dspy/examples/` which demonstrate real-world usage with DSPy integration.

## Available Examples

See `../snakepit_dspy/examples/` for:

- **`simple_qa_bypass_demo.exs`** - Direct Q&A with single worker
- **`simple_signature_demo.exs`** - Direct signature-based code review  
- **`pooled_qa_demo.exs`** - Pooled Q&A with load balancing
- **`pooled_signature_demo.exs`** - Pooled signatures with real LLM calls

These examples show real Gemini API integration through DSPy with actual language model responses.

## Usage

```bash
cd ../snakepit_dspy
elixir examples/simple_qa_bypass_demo.exs
elixir examples/pooled_qa_demo.exs
```

**Prerequisites**: Set `GEMINI_API_KEY` environment variable.