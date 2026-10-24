#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
[[ -d dist/PhotoWorkbench.app ]] || bash run_build.sh
open "$PWD/dist/PhotoWorkbench.app"
