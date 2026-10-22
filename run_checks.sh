#!/bin/bash
set -eu

cd "$(dirname "$0")"
PYTHON_CMD="/Users/cc/opt/miniconda3/envs/mydailypython/bin/python"
if [[ ! -x "$PYTHON_CMD" ]]; then
    PYTHON_CMD="python3"
fi
"$PYTHON_CMD" -m py_compile photo_time_renamer.py test_renaming.py
exec "$PYTHON_CMD" test_renaming.py
