# Python 3.13 Virtual Environment Setup Fix

**Date:** 2025-10-11
**Issue:** Python 3.13 venv creation failing with "ModuleNotFoundError: No module named 'encodings'"
**Status:** ✓ RESOLVED

## Problem

When attempting to create a Python 3.13 virtual environment using the standard `python3.13 -m venv` command, the venv would fail with:

```
ModuleNotFoundError: No module named 'encodings'
Fatal Python error: Failed to import encodings module
```

### Root Cause

Python 3.13 was installed via `uv python install 3.13`, which places the Python installation at:
```
/home/home/.local/share/uv/python/cpython-3.13.8-linux-x86_64-gnu/
```

However, the `python3.13` executable is symlinked at:
```
/home/home/.local/bin/python3.13 -> /home/home/.local/share/uv/python/cpython-3.13.8-linux-x86_64-gnu/bin/python3.13
```

When using the standard `python3.13 -m venv` command:
1. venv creates `pyvenv.cfg` with `home = /home/home/.local/bin`
2. The venv Python binary symlinks to `/home/home/.local/bin/python3.13`
3. The venv Python cannot find the standard library because it's looking relative to `/home/home/.local/bin` instead of the actual installation directory

## Solution

Use `uv venv` instead of `python3.13 -m venv` for creating virtual environments with uv-installed Python versions.

### Why it works

`uv venv` correctly identifies the actual Python installation location and sets:
```cfg
home = /home/home/.local/share/uv/python/cpython-3.13.8-linux-x86_64-gnu/bin
```

This allows the venv Python to correctly locate the standard library and all built-in modules.

## Implementation

Updated `/home/home/p/g/n/snakepit/scripts/setup_test_pythons.sh` to:
1. Check for `uv` first (preferred method)
2. Use `uv venv .venv-py313 --python 3.13` to create the virtual environment
3. Use `uv pip install` to install packages
4. Fall back to standard `python3.13 -m venv` for system-installed Python

## Verification

Created `/home/home/p/g/n/snakepit/scripts/verify_python313.sh` to verify the environment:

```bash
./scripts/verify_python313.sh
```

Checks:
- ✓ Python 3.13.8 version
- ✓ grpcio, numpy, protobuf imports
- ✓ GIL support (`sys._is_gil_enabled()`)
- ✓ Threading functionality
- ✓ grpc_server_threaded.py runs

## Commands

### Setup
```bash
# Run setup script (uses uv if available)
./scripts/setup_test_pythons.sh

# Verify installation
./scripts/verify_python313.sh
```

### Manual Verification
```bash
# Python version
.venv-py313/bin/python --version
# Output: Python 3.13.8

# Import grpc
.venv-py313/bin/python -c "import grpc; print(grpc.__version__)"
# Output: 1.75.1

# GIL status
.venv-py313/bin/python -c "import sys; print(hasattr(sys, '_is_gil_enabled'))"
# Output: True

# Run threaded server
.venv-py313/bin/python priv/python/grpc_server_threaded.py --help
```

## Environment Details

- **System:** WSL2 (Linux 6.6.87.2-microsoft-standard-WSL2)
- **Python 3.13:** cpython-3.13.8-linux-x86_64-gnu (installed via uv)
- **Python 3.12:** System Python 3.12.3 (for .venv)
- **uv version:** 0.9.1
- **Packages:** grpcio 1.75.1, numpy 2.3.3, protobuf 6.32.1

## Key Takeaways

1. **Always use `uv venv` with uv-installed Python**: Standard venv has issues with symlinked Python installations
2. **Preserved existing .venv**: Python 3.12.3 environment remains unchanged
3. **Separate environments**: `.venv` (Python 3.12) and `.venv-py313` (Python 3.13) for different test profiles
4. **GIL detection works**: Python 3.13 has `sys._is_gil_enabled()` for free-threading support

## Next Steps

- Use `.venv-py313` for testing thread profile worker pools
- Test with `PYTHON_GIL=0` environment variable for free-threading mode
- Verify multi-threaded gRPC server behavior with and without GIL
