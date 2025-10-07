# Snakepit Installation Guide

Complete installation instructions for all platforms with troubleshooting tips.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Platform-Specific Installation](#platform-specific-installation)
  - [Ubuntu/Debian](#ubuntudebian)
  - [macOS](#macos)
  - [Windows (WSL2)](#windows-wsl2)
  - [Docker](#docker)
- [Python Environment Setup](#python-environment-setup)
- [Verification](#verification)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

### Required Software

- **Elixir**: 1.18 or later
- **Erlang/OTP**: 27 or later
- **Python**: 3.8 or later (for Python gRPC adapter)
- **pip**: Python package manager

### Optional Tools

- **Docker**: For containerized deployments
- **make**: For running build scripts
- **git**: For GitHub installation

---

## Quick Start

### 1. Add Snakepit to Your Project

**From Hex (Recommended)**:
```elixir
# mix.exs
def deps do
  [
    {:snakepit, "~> 0.4.1"}
  ]
end
```

**From GitHub (Latest)**:
```elixir
def deps do
  [
    {:snakepit, github: "nshkrdotcom/snakepit"}
  ]
end
```

Then run:
```bash
mix deps.get
mix compile
```

### 2. Install Python Dependencies

**Using pip**:
```bash
# Navigate to your deps directory
cd deps/snakepit/priv/python

# Install required packages
pip install -r requirements.txt
```

**Or install globally**:
```bash
pip install grpcio>=1.60.0 grpcio-tools>=1.60.0 protobuf>=4.25.0 numpy>=1.21.0
```

### 3. Verify Installation

```bash
# Test Python dependencies
python3 -c "import grpc; print('gRPC:', grpc.__version__)"

# Run Snakepit tests
cd ../../..  # Back to your project root
mix test
```

---

## Platform-Specific Installation

### Ubuntu/Debian

#### 1. Install System Dependencies

```bash
# Update package lists
sudo apt update

# Install Erlang and Elixir
sudo apt install -y erlang elixir

# Install Python 3 and pip
sudo apt install -y python3 python3-pip python3-venv

# Install build tools (optional, for compiling native extensions)
sudo apt install -y build-essential python3-dev
```

#### 2. Verify Versions

```bash
elixir --version
# Elixir 1.18.4 (compiled with Erlang/OTP 27)

python3 --version
# Python 3.10.12 (or later)

pip3 --version
# pip 22.0.2 (or later)
```

#### 3. Create Python Virtual Environment (Recommended)

```bash
# Create a virtual environment for your project
python3 -m venv .venv

# Activate it
source .venv/bin/activate

# Upgrade pip
pip install --upgrade pip
```

#### 4. Install Snakepit Python Dependencies

```bash
# If using deps/snakepit
cd deps/snakepit/priv/python && pip install -r requirements.txt

# Or install packages directly
pip install grpcio>=1.60.0 grpcio-tools>=1.60.0 protobuf>=4.25.0 numpy>=1.21.0
```

#### Ubuntu-Specific Notes

- **Python 3.8 on older Ubuntu**: Use deadsnakes PPA
  ```bash
  sudo add-apt-repository ppa:deadsnakes/ppa
  sudo apt update
  sudo apt install python3.10 python3.10-venv python3.10-dev
  ```

- **Erlang/Elixir from Erlang Solutions**: For latest versions
  ```bash
  wget https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb
  sudo dpkg -i erlang-solutions_2.0_all.deb
  sudo apt update
  sudo apt install esl-erlang elixir
  ```

---

### macOS

#### 1. Install Homebrew (if not already installed)

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

#### 2. Install Dependencies

```bash
# Install Erlang and Elixir
brew install erlang elixir

# Python 3 comes with macOS, but install latest version
brew install python@3.11

# Verify installations
elixir --version
python3 --version
```

#### 3. Create Virtual Environment

```bash
# Create virtual environment
python3 -m venv .venv

# Activate (macOS/Linux)
source .venv/bin/activate

# Upgrade pip
pip install --upgrade pip
```

#### 4. Install Python Dependencies

```bash
cd deps/snakepit/priv/python
pip install -r requirements.txt
```

#### macOS-Specific Notes

- **M1/M2 Macs**: grpcio may require Rosetta or ARM-native builds
  ```bash
  # If you encounter architecture issues:
  arch -arm64 pip install grpcio grpcio-tools
  ```

- **Using asdf**: For version management
  ```bash
  brew install asdf
  asdf plugin add erlang
  asdf plugin add elixir
  asdf plugin add python

  asdf install erlang 27.0
  asdf install elixir 1.18.4-otp-27
  asdf install python 3.11.8

  asdf global erlang 27.0
  asdf global elixir 1.18.4-otp-27
  asdf global python 3.11.8
  ```

---

### Windows (WSL2)

**Recommended**: Use Windows Subsystem for Linux 2 (WSL2) with Ubuntu.

#### 1. Enable WSL2

```powershell
# Run in PowerShell as Administrator
wsl --install -d Ubuntu-22.04
```

#### 2. Follow Ubuntu Instructions

Once in WSL2 Ubuntu, follow the [Ubuntu/Debian](#ubuntudebian) instructions above.

#### 3. WSL-Specific Configuration

```bash
# Ensure WSL can access localhost ports
# (Usually works by default in WSL2)

# If you encounter networking issues:
# Add to /etc/wsl.conf
[network]
generateResolvConf = false

# Then restart WSL from PowerShell:
# wsl --shutdown
```

#### Windows Native (Not Recommended)

While possible, native Windows installation is complex. WSL2 is strongly recommended for better compatibility.

---

### Docker

#### 1. Create Dockerfile

```dockerfile
# Dockerfile
FROM elixir:1.18.4-otp-27-alpine

# Install Python and build dependencies
RUN apk add --no-cache \
    python3 \
    py3-pip \
    python3-dev \
    build-base \
    git

# Set working directory
WORKDIR /app

# Copy mix files
COPY mix.exs mix.lock ./
COPY config config

# Install Elixir dependencies
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get && \
    mix deps.compile

# Install Python dependencies
RUN pip3 install --no-cache-dir \
    grpcio>=1.60.0 \
    grpcio-tools>=1.60.0 \
    protobuf>=4.25.0 \
    numpy>=1.21.0

# Copy application code
COPY . .

# Compile application
RUN mix compile

# Expose gRPC port range
EXPOSE 50051-50151

# Run the application
CMD ["mix", "run", "--no-halt"]
```

#### 2. Build and Run

```bash
# Build image
docker build -t myapp-snakepit .

# Run container
docker run -p 4000:4000 -p 50051-50151:50051-50151 myapp-snakepit
```

#### 3. Docker Compose

```yaml
# docker-compose.yml
version: '3.8'

services:
  app:
    build: .
    ports:
      - "4000:4000"
      - "50051-50151:50051-50151"
    environment:
      - MIX_ENV=prod
      - SNAKEPIT_GRPC_PORT=50051
    volumes:
      - ./config:/app/config
    restart: unless-stopped
```

---

## Python Environment Setup

### Option 1: Virtual Environment (Recommended)

**Benefits**: Isolated dependencies, no global pollution, reproducible

```bash
# Create virtual environment
python3 -m venv .venv

# Activate
source .venv/bin/activate  # Linux/macOS
# OR
.venv\Scripts\activate     # Windows

# Install dependencies
pip install -r deps/snakepit/priv/python/requirements.txt

# Deactivate when done
deactivate
```

**Important**: Remember to activate the venv before running your Elixir app:
```bash
source .venv/bin/activate && iex -S mix
```

### Option 2: System-Wide Installation

**Benefits**: Always available, simpler

```bash
pip3 install --user grpcio grpcio-tools protobuf numpy
```

### Option 3: Poetry (Python Project Management)

```bash
# Install poetry
curl -sSL https://install.python-poetry.org | python3 -

# Create pyproject.toml in your project root
cat > pyproject.toml << 'EOF'
[tool.poetry]
name = "myapp"
version = "0.1.0"

[tool.poetry.dependencies]
python = "^3.8"
grpcio = ">=1.60.0"
grpcio-tools = ">=1.60.0"
protobuf = ">=4.25.0"
numpy = ">=1.21.0"
EOF

# Install dependencies
poetry install

# Run your app with poetry environment
poetry run iex -S mix
```

### Option 4: Conda/Miniconda

```bash
# Create conda environment
conda create -n myapp python=3.11

# Activate
conda activate myapp

# Install dependencies
pip install grpcio grpcio-tools protobuf numpy
```

---

## Verification

### 1. Verify Elixir Dependencies

```bash
mix deps.get
mix compile
```

**Expected output**:
```
==> snakepit
Compiling 40 files (.ex)
Generated snakepit app
```

### 2. Verify Python Dependencies

```bash
python3 << 'EOF'
import sys
import grpc
import grpc_tools
import google.protobuf
import numpy

print("✅ Python version:", sys.version)
print("✅ gRPC version:", grpc.__version__)
print("✅ gRPC tools version:", grpc_tools.__version__)
print("✅ Protobuf version:", google.protobuf.__version__)
print("✅ NumPy version:", numpy.__version__)
print("\n🎉 All Python dependencies are installed correctly!")
EOF
```

**Expected output**:
```
✅ Python version: 3.11.8 (main, ...)
✅ gRPC version: 1.62.1
✅ gRPC tools version: 1.62.1
✅ Protobuf version: 4.25.3
✅ NumPy version: 1.26.4

🎉 All Python dependencies are installed correctly!
```

### 3. Run Tests

```bash
mix test
```

**Expected output**:
```
Running ExUnit with seed: ...
..........
Finished in X.X seconds
160 tests, 0 failures
```

**Note**: Tests will pass even without Python dependencies installed. Some tests mock Python interactions, and others gracefully handle missing Python servers.

### 4. Run Example

```bash
# Simple example (requires Python gRPC)
elixir examples/grpc_basic.exs
```

**Expected output**:
```
=== Basic gRPC Example ===

1. Ping command:
Ping result: %{"status" => "ok", "timestamp" => ...}

2. Echo command:
Echo result: %{"message" => "Hello from gRPC!", ...}
...
```

If you see `ModuleNotFoundError: No module named 'grpc'`, Python dependencies are not installed correctly.

---

## Troubleshooting

### Issue: `No module named 'grpc'`

**Symptom**:
```
ModuleNotFoundError: No module named 'grpc'
```

**Solutions**:

1. **Check Python path**:
   ```bash
   which python3
   python3 -m pip list | grep grpc
   ```

2. **Install in correct environment**:
   ```bash
   # If using venv
   source .venv/bin/activate
   pip install grpcio grpcio-tools

   # If system-wide
   pip3 install --user grpcio grpcio-tools
   ```

3. **Verify installation**:
   ```bash
   python3 -c "import grpc; print(grpc.__file__)"
   ```

### Issue: `grpcio` Compilation Fails

**Symptom**:
```
error: command 'gcc' failed with exit status 1
```

**Solutions**:

**Ubuntu/Debian**:
```bash
sudo apt install -y build-essential python3-dev
pip install --upgrade pip setuptools wheel
pip install grpcio
```

**macOS**:
```bash
xcode-select --install
pip install --upgrade pip setuptools wheel
pip install grpcio
```

**Use pre-built wheels**:
```bash
pip install --only-binary :all: grpcio grpcio-tools
```

### Issue: Port Binding Errors

**Symptom**:
```
[error] Failed to bind to port 50051: already in use
```

**Solutions**:

1. **Check for existing processes**:
   ```bash
   lsof -i :50051
   # Or
   netstat -tuln | grep 50051
   ```

2. **Kill orphaned Python processes**:
   ```bash
   pkill -f grpc_server.py
   ```

3. **Change port range** in config:
   ```elixir
   config :snakepit,
     grpc_config: %{
       base_port: 60051,  # Use different port range
       port_range: 100
     }
   ```

### Issue: Worker Startup Timeouts

**Symptom**:
```
[error] Worker startup timeout after 10000ms
```

**Solutions**:

1. **Increase timeout**:
   ```elixir
   config :snakepit,
     pool_startup_timeout: 30_000  # 30 seconds
   ```

2. **Reduce pool size** (for slower machines):
   ```elixir
   config :snakepit,
     pool_config: %{
       pool_size: 2  # Start with smaller pool
     }
   ```

3. **Check Python server startup**:
   ```bash
   # Test Python server manually
   cd deps/snakepit/priv/python
   python3 grpc_server.py --port 50051
   ```

### Issue: Elixir/Erlang Version Mismatch

**Symptom**:
```
** (UndefinedFunctionError) function X is undefined
```

**Solutions**:

1. **Check versions**:
   ```bash
   elixir --version
   ```

2. **Install correct versions**:
   ```bash
   # Using asdf
   asdf install erlang 27.0
   asdf install elixir 1.18.4-otp-27

   # Or via package manager (see platform-specific sections)
   ```

### Issue: Mix Dependency Conflicts

**Symptom**:
```
** (Mix) Dependency resolution failed
```

**Solutions**:

1. **Clean and reinstall**:
   ```bash
   mix deps.clean --all
   mix deps.get
   mix compile
   ```

2. **Check for version conflicts** in `mix.lock`:
   ```bash
   rm mix.lock
   mix deps.get
   ```

### Issue: Virtual Environment Not Activating

**Symptom**:
```
bash: .venv/bin/activate: No such file or directory
```

**Solutions**:

1. **Create venv first**:
   ```bash
   python3 -m venv .venv
   source .venv/bin/activate
   ```

2. **Use full path**:
   ```bash
   source /full/path/to/.venv/bin/activate
   ```

3. **Check Python venv module**:
   ```bash
   # Ubuntu/Debian
   sudo apt install python3-venv
   ```

### Issue: Permission Denied on Linux

**Symptom**:
```
Permission denied: '/usr/local/lib/python3.X/site-packages'
```

**Solutions**:

1. **Use `--user` flag**:
   ```bash
   pip3 install --user grpcio grpcio-tools
   ```

2. **Use virtual environment** (recommended):
   ```bash
   python3 -m venv .venv
   source .venv/bin/activate
   pip install grpcio grpcio-tools
   ```

3. **Use sudo** (not recommended):
   ```bash
   sudo pip3 install grpcio grpcio-tools
   ```

---

## Additional Resources

- **Snakepit Documentation**: [README.md](../README.md)
- **Elixir Installation**: https://elixir-lang.org/install.html
- **Python Installation**: https://www.python.org/downloads/
- **gRPC Python Quickstart**: https://grpc.io/docs/languages/python/quickstart/
- **asdf Version Manager**: https://asdf-vm.com/

---

## Getting Help

If you encounter issues not covered here:

1. **Check existing issues**: https://github.com/nshkrdotcom/snakepit/issues
2. **Open a new issue**: Include:
   - Platform (Ubuntu 22.04, macOS 14, etc.)
   - Elixir version (`elixir --version`)
   - Python version (`python3 --version`)
   - Error messages (full output)
   - Steps to reproduce

3. **Community support**:
   - Elixir Forum: https://elixirforum.com/
   - Elixir Slack: https://elixir-slackin.herokuapp.com/

---

**Next Steps**: After successful installation, see the [Quick Start Guide](../README.md#quick-start) for usage examples.
