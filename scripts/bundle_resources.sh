#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash run_prepare.sh --verify
resource_dir="$1"
mkdir -p "$resource_dir/Engines" "$resource_dir/Notices"
cp -R vendor/Engines/. "$resource_dir/Engines/"
cp -R vendor/Notices/. "$resource_dir/Notices/"
cp dependencies.lock.json THIRD_PARTY.md "$resource_dir/Notices/"
for engine in "$resource_dir"/Engines/*; do
    chmod u+w "$engine"
    codesign --force --sign - "$engine" >/dev/null 2>&1
done
if [[ -f native/AppIcon.icns ]]; then cp native/AppIcon.icns "$resource_dir/"; fi
