#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bash scripts/run_prepare.sh
mkdir -p build dist
xcodebuild -project PhotoWorkbench.xcodeproj -scheme PhotoWorkbench -configuration Release -derivedDataPath "$PWD/build/DerivedData" build >build/build.log 2>&1 || { tail -100 build/build.log; exit 1; }
ditto build/DerivedData/Build/Products/Release/PhotoWorkbench.app dist/PhotoWorkbench.app
codesign --verify --deep --strict dist/PhotoWorkbench.app
printf '%s\n' "$PWD/dist/PhotoWorkbench.app"
