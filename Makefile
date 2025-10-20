# Snakepit gRPC Development Makefile

# Directories
PROTO_DIR = priv/proto
PYTHON_OUT_DIR = priv/python
ELIXIR_OUT_DIR = lib/snakepit/grpc

# Protocol buffer source
PROTO_FILE = $(PROTO_DIR)/snakepit_bridge.proto

# Python gRPC files
PYTHON_GRPC_FILES = $(PYTHON_OUT_DIR)/snakepit_bridge_pb2.py $(PYTHON_OUT_DIR)/snakepit_bridge_pb2_grpc.py

.PHONY: all clean proto-python proto-elixir install-dev test help

# Python interpreter (prefer local virtualenv, fallback to python3/python)
PYTHON ?= $(shell if [ -x ".venv/bin/python" ]; then echo "./.venv/bin/python"; elif command -v python3 >/dev/null 2>&1; then echo "python3"; else echo "python"; fi)

# Default target
all: proto-python

# Generate Python gRPC code
proto-python: $(PYTHON_GRPC_FILES)

$(PYTHON_GRPC_FILES): $(PROTO_FILE)
	@echo "Generating Python gRPC code..."
	@mkdir -p $(PYTHON_OUT_DIR)
	@touch $(PYTHON_OUT_DIR)/__init__.py
	$(PYTHON) -m grpc_tools.protoc \
		--proto_path=$(PROTO_DIR) \
		--python_out=$(PYTHON_OUT_DIR) \
		--grpc_python_out=$(PYTHON_OUT_DIR) \
		$(PROTO_FILE)
	@echo "✅ Python gRPC code generated"

# Generate Elixir gRPC code (future)
proto-elixir:
	@echo "Elixir gRPC generation not implemented yet"
	@echo "Will use protoc-gen-elixir when ready"

# Install development dependencies
install-dev:
	@echo "Installing Python development dependencies..."
	cd priv/python && pip install -e ".[dev]"
	@echo "✅ Development dependencies installed"

# Install just gRPC dependencies 
install-grpc:
	@echo "Installing gRPC dependencies..."
	cd priv/python && pip install -e ".[grpc]"
	@echo "✅ gRPC dependencies installed"

# Clean generated files
clean:
	@echo "Cleaning generated files..."
	rm -rf $(PYTHON_OUT_DIR)
	rm -rf $(ELIXIR_OUT_DIR)
	@echo "✅ Cleaned"

# Run tests
test:
	@echo "Running tests..."
	PYTHONPATH=priv/python $(PYTHON) -m pytest priv/python/tests
	mix test --color

# Show help
help:
	@echo "Available targets:"
	@echo "  all           - Generate all protocol files (currently just Python)"
	@echo "  proto-python  - Generate Python gRPC code from .proto files"
	@echo "  proto-elixir  - Generate Elixir gRPC code (not implemented)"
	@echo "  install-dev   - Install Python development dependencies"
	@echo "  install-grpc  - Install just gRPC dependencies"
	@echo "  clean         - Remove generated files"
	@echo "  test          - Run all tests"
	@echo "  help          - Show this help message"

# Development workflow
dev-setup: install-dev proto-python
	@echo "✅ Development environment ready"
	@echo "Next steps:"
	@echo "  1. Implement gRPC server: python priv/python/grpc_bridge.py"
	@echo "  2. Test with: make test"
