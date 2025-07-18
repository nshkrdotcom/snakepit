# Python Bridge V2 - Package Overhaul

## Overview

The Python Bridge has been completely overhauled from a fragile sys.path-based approach to a robust, production-ready package structure. This addresses the original fragility issue where custom bridges relied on being in the same directory as the generic bridge.

## Key Improvements

### 🏗️ Proper Package Structure
- **Before**: Fragile `sys.path.insert()` manipulation requiring same-directory placement
- **After**: Proper Python package with `snakepit_bridge` namespace and relative imports

### 📦 Package Installation Support
- **Before**: No installation mechanism, manual script execution only
- **After**: Full `pip install` support with console scripts and development mode

### 🔧 Dual Mode Operation
- **Development Mode**: Uses V2 scripts with local package imports (fallback)
- **Production Mode**: Uses installed console scripts for system-wide availability

### 🧪 Enhanced Testing
- Comprehensive test suite for the new V2 adapter
- Package structure validation
- Installation mode detection

## Package Structure

```
priv/python/
├── snakepit_bridge/              # Main package
│   ├── __init__.py              # Package init with exports
│   ├── core.py                  # Protocol handling and base classes
│   ├── py.typed                 # Type checking marker
│   ├── adapters/                # Adapter implementations
│   │   ├── __init__.py
│   │   └── generic.py           # Generic command handler
│   └── cli/                     # Console script entry points
│       ├── __init__.py
│       ├── generic.py           # Generic bridge CLI
│       └── custom.py            # Custom bridge CLI
├── setup.py                     # Package installation script
├── generic_bridge_v2.py         # Development script (new)
├── example_custom_bridge_v2.py  # Development script (new)
├── generic_bridge.py            # Legacy script (maintained)
└── example_custom_bridge.py     # Legacy script (maintained)
```

## Installation Options

### Option 1: Development Install (Recommended)
```bash
cd priv/python
pip install -e .
```

### Option 2: Regular Install
```bash
cd priv/python
pip install .
```

### Option 3: Development Mode (No Installation)
Uses V2 scripts with automatic package path detection.

## Console Scripts

After installation, these commands become available system-wide:

```bash
# Generic bridge
snakepit-generic-bridge --help
snakepit-generic-bridge  # Run in pool-worker mode

# Custom bridge example
snakepit-custom-bridge --help
snakepit-custom-bridge   # Run in pool-worker mode
```

## Elixir Integration

### New V2 Adapter

```elixir
# Use the new V2 adapter in config
config :snakepit,
  adapter_module: Snakepit.Adapters.GenericPythonV2
```

The V2 adapter automatically detects:
- ✅ Console script availability (production mode)
- ✅ Development script fallback
- ✅ Package structure validation

### Backward Compatibility

The original `Snakepit.Adapters.GenericPython` continues to work unchanged, using the legacy scripts.

## Creating Custom Bridges

### V2 Approach (Recommended)

```python
from snakepit_bridge import BaseCommandHandler, ProtocolHandler
from snakepit_bridge.core import setup_graceful_shutdown, setup_broken_pipe_suppression

class MyCustomHandler(BaseCommandHandler):
    def _register_commands(self):
        self.register_command("my_command", self.handle_my_command)
    
    def handle_my_command(self, args):
        return {"result": "processed", "input": args}

def main():
    setup_broken_pipe_suppression()
    
    command_handler = MyCustomHandler()
    protocol_handler = ProtocolHandler(command_handler)
    setup_graceful_shutdown(protocol_handler)
    
    protocol_handler.run()
```

### Key Benefits
- ✅ **No sys.path manipulation** - proper imports
- ✅ **Location independent** - works from any directory
- ✅ **Type checking support** - includes py.typed marker
- ✅ **Production ready** - installable package
- ✅ **Graceful shutdown** - proper signal handling
- ✅ **Error handling** - robust broken pipe management

## Testing

### Run V2 Tests
```bash
mix test test/snakepit/adapters/generic_python_v2_test.exs
```

### Test Package Installation
```bash
# Test development scripts
python3 generic_bridge_v2.py --help
python3 example_custom_bridge_v2.py --help

# Test installed console scripts (after pip install)
snakepit-generic-bridge --help
snakepit-custom-bridge --help
```

## Migration Path

### For Existing Users
1. **No immediate action required** - legacy scripts continue working
2. **Optional upgrade** to V2 adapter for enhanced robustness
3. **Optional installation** for system-wide console scripts

### For New Projects
1. **Use V2 adapter**: `Snakepit.Adapters.GenericPythonV2`
2. **Install package**: `pip install -e priv/python`
3. **Create custom bridges** using the V2 pattern

## Verification Commands

```bash
# Test the package structure
mix test test/snakepit/adapters/generic_python_v2_test.exs

# Test development scripts
python3 priv/python/generic_bridge_v2.py --help
python3 priv/python/example_custom_bridge_v2.py --help

# Install and test console scripts
cd priv/python && pip install -e .
snakepit-generic-bridge --help
snakepit-custom-bridge --help

# Check package detection in Elixir
iex -S mix
iex> Snakepit.Adapters.GenericPythonV2.package_installed?()
iex> Snakepit.Adapters.GenericPythonV2.installation_instructions()
```

## Files Created/Modified

### New Files
- `snakepit_bridge/` - Complete package structure
- `setup.py` - Package installation script  
- `generic_bridge_v2.py` - Development script using package
- `example_custom_bridge_v2.py` - Custom bridge using package
- `lib/snakepit/adapters/generic_python_v2.ex` - V2 Elixir adapter
- `test/snakepit/adapters/generic_python_v2_test.exs` - Comprehensive tests

### Preserved Files
- `generic_bridge.py` - Legacy script (unchanged)
- `example_custom_bridge.py` - Legacy script (unchanged)
- `lib/snakepit/adapters/generic_python.ex` - Legacy adapter (unchanged)

## Summary

The Python Bridge V2 overhaul transforms the bridge from a fragile development-only system to a robust, production-ready package that supports:

- 🏭 **Production deployment** with proper package installation
- 🔧 **Development workflow** with automatic fallback
- 🛡️ **Robust imports** without path manipulation
- 📍 **Location independence** - no same-directory requirement
- 🧪 **Comprehensive testing** with automated validation
- 🔄 **Backward compatibility** with existing code

The fragile sys.path approach is now completely eliminated in favor of proper Python packaging standards.