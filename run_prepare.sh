#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
python_cmd=/Users/cc/opt/miniconda3/envs/mydailypython/bin/python
[[ -x "$python_cmd" ]] || python_cmd=python3
exec "$python_cmd" scripts/prepare.py "$@"
