#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python_cmd="${PYTHON:-python3}"
exec "$python_cmd" scripts/prepare.py "$@"
