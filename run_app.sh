#!/bin/bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec /bin/zsh "$SCRIPT_DIR/RunPhotoTimeRenamer.command"
