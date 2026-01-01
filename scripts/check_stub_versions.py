#!/usr/bin/env python3
"""
CI guard: Verify that generated protobuf/grpc stubs are compatible with requirements.txt.

This script parses the version requirements from:
1. Generated stubs (snakepit_bridge_pb2.py, snakepit_bridge_pb2_grpc.py)
2. requirements.txt

And fails if the declared minimums in requirements.txt are lower than what
the generated stubs require.

Usage:
    python scripts/check_stub_versions.py

Exit codes:
    0 - All versions are compatible
    1 - Version mismatch detected
"""

import re
import sys
from pathlib import Path


def parse_requirements(req_path: Path) -> dict:
    """Parse requirements.txt and return package->min_version mapping."""
    requirements = {}
    if not req_path.exists():
        print(f"ERROR: {req_path} not found")
        sys.exit(1)

    with open(req_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            # Match patterns like: grpcio>=1.76.0
            match = re.match(r"([a-zA-Z0-9_-]+)>=([0-9.]+)", line)
            if match:
                requirements[match.group(1).lower()] = match.group(2)
    return requirements


def parse_pb2_version(pb2_path: Path) -> str:
    """Extract Protobuf Python Version from generated pb2.py file."""
    if not pb2_path.exists():
        print(f"ERROR: {pb2_path} not found")
        sys.exit(1)

    with open(pb2_path) as f:
        content = f.read()

    # Look for: # Protobuf Python Version: 6.31.1
    match = re.search(r"#\s*Protobuf Python Version:\s*([0-9.]+)", content)
    if match:
        return match.group(1)

    # Also check for ValidateProtobufRuntimeVersion call
    match = re.search(r"ValidateProtobufRuntimeVersion\s*\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)", content)
    if match:
        return f"{match.group(1)}.{match.group(2)}.{match.group(3)}"

    return None


def parse_grpc_version(grpc_path: Path) -> str:
    """Extract GRPC_GENERATED_VERSION from generated grpc file."""
    if not grpc_path.exists():
        print(f"ERROR: {grpc_path} not found")
        sys.exit(1)

    with open(grpc_path) as f:
        content = f.read()

    # Look for: GRPC_GENERATED_VERSION = '1.76.0'
    match = re.search(r"GRPC_GENERATED_VERSION\s*=\s*['\"]([0-9.]+)['\"]", content)
    if match:
        return match.group(1)

    return None


def version_tuple(v: str) -> tuple:
    """Convert version string to tuple for comparison."""
    return tuple(int(x) for x in v.split("."))


def check_version_compat(name: str, required: str, declared: str) -> bool:
    """Check if declared minimum >= required version."""
    if required is None:
        print(f"  {name}: Could not determine required version from stubs")
        return True  # Can't check, assume OK

    if declared is None:
        print(f"  {name}: Not found in requirements.txt")
        return False

    req_tuple = version_tuple(required)
    decl_tuple = version_tuple(declared)

    if decl_tuple >= req_tuple:
        print(f"  {name}: OK (requirements {declared} >= stubs {required})")
        return True
    else:
        print(f"  {name}: MISMATCH (requirements {declared} < stubs {required})")
        return False


def main():
    # Determine paths
    script_dir = Path(__file__).parent
    project_root = script_dir.parent
    python_dir = project_root / "priv" / "python"

    pb2_path = python_dir / "snakepit_bridge_pb2.py"
    grpc_path = python_dir / "snakepit_bridge_pb2_grpc.py"
    req_path = python_dir / "requirements.txt"

    print("Checking generated stub versions against requirements.txt...")
    print()

    # Parse versions
    requirements = parse_requirements(req_path)
    protobuf_required = parse_pb2_version(pb2_path)
    grpcio_required = parse_grpc_version(grpc_path)

    print(f"From stubs:")
    print(f"  protobuf required: {protobuf_required or 'unknown'}")
    print(f"  grpcio required: {grpcio_required or 'unknown'}")
    print()
    print(f"From requirements.txt:")
    print(f"  protobuf declared: {requirements.get('protobuf', 'not found')}")
    print(f"  grpcio declared: {requirements.get('grpcio', 'not found')}")
    print(f"  grpcio-tools declared: {requirements.get('grpcio-tools', 'not found')}")
    print()
    print("Compatibility check:")

    # Check compatibility
    all_ok = True
    all_ok &= check_version_compat("protobuf", protobuf_required, requirements.get("protobuf"))
    all_ok &= check_version_compat("grpcio", grpcio_required, requirements.get("grpcio"))
    # grpcio-tools should also match the generated version (used for code generation)
    all_ok &= check_version_compat("grpcio-tools", grpcio_required, requirements.get("grpcio-tools"))

    print()
    if all_ok:
        print("All version checks passed.")
        sys.exit(0)
    else:
        print("VERSION MISMATCH DETECTED!")
        print()
        print("To fix:")
        print("  1. Update requirements.txt to match the generated stub versions, OR")
        print("  2. Regenerate stubs using older protoc/grpc-tools versions")
        sys.exit(1)


if __name__ == "__main__":
    main()
