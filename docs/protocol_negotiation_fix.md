# Protocol Negotiation Fix

## Issue
When running tests, the Python bridge was printing "Protocol negotiation failed, defaulting to JSON" warnings even though the test configuration explicitly set `wire_protocol: :json`.

## Root Cause
1. The Elixir worker correctly skipped protocol negotiation when `wire_protocol` was not `:auto`
2. However, the Python bridge was always initialized with `protocol="auto"` (the default)
3. The Python bridge expected a negotiation message that never came, causing it to print the warning and default to JSON

## Solution
Modified the adapter to pass the wire protocol configuration to the Python bridge via command line arguments:

1. **Updated `generic_bridge_v2.py`** to accept a `--protocol` argument
2. **Updated `Snakepit.Adapters.GenericPythonV2.script_args/0`** to include the protocol configuration based on the `wire_protocol` setting

Now when `wire_protocol` is set to `:json` or `:msgpack`, the Python bridge starts with the correct protocol without attempting negotiation.

## Benefits
- Eliminates unnecessary warning messages in test output
- Slightly faster startup (no negotiation timeout)
- More explicit configuration flow
- Better alignment between Elixir and Python sides

## Testing
All tests pass with the fix applied. The Python bridge correctly uses the configured protocol without negotiation warnings.