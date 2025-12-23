from pathlib import Path
import os
import sys

PYTHON_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PYTHON_ROOT))

os.environ.setdefault("OTEL_TRACES_EXPORTER", "none")
os.environ.setdefault("SNAKEPIT_OTEL_CONSOLE", "false")
