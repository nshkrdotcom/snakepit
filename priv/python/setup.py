#!/usr/bin/env python3
"""
Setup script for Snakepit Bridge Package

Install with:
    pip install -e .  # Development install
    pip install .     # Regular install

Or build wheel:
    python setup.py bdist_wheel
"""

from setuptools import setup, find_packages
import os

# Read version from package
def get_version():
    version_file = os.path.join(os.path.dirname(__file__), 'snakepit_bridge', '__init__.py')
    with open(version_file, 'r') as f:
        for line in f:
            if line.startswith('__version__'):
                return line.split('=')[1].strip().strip('"\'')
    return '2.0.0'

# Read README if it exists
def get_long_description():
    readme_path = os.path.join(os.path.dirname(__file__), '..', '..', 'README.md')
    if os.path.exists(readme_path):
        with open(readme_path, 'r', encoding='utf-8') as f:
            return f.read()
    return "Snakepit Bridge Package - Production-ready Python bridge for Snakepit pool communication"

setup(
    name="snakepit-bridge",
    version=get_version(),
    author="Snakepit Team",
    author_email="team@snakepit.dev",
    description="Production-ready Python bridge for Snakepit pool communication",
    long_description=get_long_description(),
    long_description_content_type="text/markdown",
    url="https://github.com/snakepit/snakepit",
    packages=find_packages(),
    classifiers=[
        "Development Status :: 4 - Beta",
        "Intended Audience :: Developers",
        "License :: OSI Approved :: MIT License",
        "Operating System :: OS Independent",
        "Programming Language :: Python :: 3",
        "Programming Language :: Python :: 3.8",
        "Programming Language :: Python :: 3.9",
        "Programming Language :: Python :: 3.10",
        "Programming Language :: Python :: 3.11",
        "Programming Language :: Python :: 3.12",
        "Topic :: Software Development :: Libraries :: Python Modules",
        "Topic :: System :: Distributed Computing",
    ],
    python_requires=">=3.8",
    install_requires=[
        "grpcio>=1.60.0",
        "grpcio-tools>=1.60.0",
        "protobuf>=4.25.0",
        "numpy>=1.21.0",
        "psutil>=5.9.0",
        "opentelemetry-api>=1.21.0",
        "opentelemetry-sdk>=1.21.0",
        "opentelemetry-exporter-otlp-proto-http>=1.21.0",
    ],
    extras_require={
        "grpc": [
            "grpcio>=1.50.0",
            "protobuf>=4.0.0",
            "opentelemetry-api>=1.21.0",
            "opentelemetry-sdk>=1.21.0",
            "opentelemetry-exporter-otlp-proto-http>=1.21.0",
        ],
        "msgpack": [
            "msgpack>=1.0.5",
        ],
        "all": [
            "grpcio>=1.50.0",
            "protobuf>=4.0.0",
            "opentelemetry-api>=1.21.0",
            "opentelemetry-sdk>=1.21.0",
            "opentelemetry-exporter-otlp-proto-http>=1.21.0",
            "msgpack>=1.0.5",
        ],
        "dev": [
            "pytest>=7.0",
            "pytest-cov>=2.0",
            "black>=22.0",
            "flake8>=4.0",
            "mypy>=0.900",
            "grpcio>=1.50.0",
            "protobuf>=4.0.0",
            "grpcio-tools>=1.50.0",  # For protoc compilation
            "opentelemetry-api>=1.21.0",
            "opentelemetry-sdk>=1.21.0",
            "opentelemetry-exporter-otlp-proto-http>=1.21.0",
        ],
    },
    entry_points={
        "console_scripts": [
            "snakepit-generic-bridge=snakepit_bridge.cli.generic:main",
            "snakepit-custom-bridge=snakepit_bridge.cli.custom:main",
        ],
    },
    package_data={
        "snakepit_bridge": ["py.typed"],
    },
    include_package_data=True,
    zip_safe=False,
)
