#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
[[ -f vendor/.prepared ]] || { echo 'Run bash run_prepare.sh first.'; exit 1; }
bash run_prepare.sh --verify
mkdir -p build dist
xcodebuild -project PhotoWorkbench.xcodeproj -scheme PhotoWorkbench -configuration Release -derivedDataPath "$PWD/build/DerivedData" build >build/build.log 2>&1 || { tail -100 build/build.log; exit 1; }
ditto build/DerivedData/Build/Products/Release/PhotoWorkbench.app dist/PhotoWorkbench.app
codesign --verify --deep --strict dist/PhotoWorkbench.app
printf '%s\n' "$PWD/dist/PhotoWorkbench.app"
