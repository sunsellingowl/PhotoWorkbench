#!/bin/zsh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SCRIPT="$SCRIPT_DIR/photo_time_renamer.py"

if [[ ! -f "$APP_SCRIPT" ]]; then
  echo "Error: Cannot find photo_time_renamer.py"
  echo "Expected at: $APP_SCRIPT"
  read "?Press Enter to close..."
  exit 1
fi

PYTHON_CMD=""

if [[ -x "/Users/cc/opt/miniconda3/envs/mydailypython/bin/python" ]]; then
  PYTHON_CMD="/Users/cc/opt/miniconda3/envs/mydailypython/bin/python"
elif [[ -x "/Users/cc/opt/miniconda3/bin/python" ]]; then
  PYTHON_CMD="/Users/cc/opt/miniconda3/bin/python"
elif command -v python3 >/dev/null 2>&1; then
  PYTHON_CMD="$(command -v python3)"
fi

if [[ -z "$PYTHON_CMD" ]]; then
  echo "Error: Python was not found."
  echo "Install Python 3 and Pillow first: pip install Pillow"
  read "?Press Enter to close..."
  exit 1
fi

echo "Using Python: $PYTHON_CMD"
"$PYTHON_CMD" "$APP_SCRIPT"
EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
  echo ""
  echo "App exited with error code: $EXIT_CODE"
  echo "If Pillow is missing, run: pip install Pillow"
  read "?Press Enter to close..."
  exit $EXIT_CODE
fi
