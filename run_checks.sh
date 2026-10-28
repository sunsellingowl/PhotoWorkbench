#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/build/ModuleCache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-$PWD/build/ModuleCache}"
if [[ "${1:-}" != --skip-build ]]; then bash run_build.sh; fi
python_cmd="${PYTHON:-python3}"
"$python_cmd" tests/make_fixtures.py build/fixtures
check_app="$PWD/build/NativeChecks.app"
mkdir -p "$check_app/Contents/MacOS"
cp native/Info.plist "$check_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable NativeChecks' "$check_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.cc.PhotoWorkbench.NativeChecks' "$check_app/Contents/Info.plist"
bash scripts/bundle_resources.sh "$check_app/Contents/Resources"
object_dir="$PWD/build/DerivedData/Build/Intermediates.noindex/PhotoWorkbench.build/Release/PhotoWorkbench.build/Objects-normal/arm64"
objects=()
for obj in "$object_dir"/*.o; do
    case "$(basename "$obj")" in ExifDates.o|PhotoCore.o|WorkbenchModel.o|PhotoWorkbenchApp.o) ;; *) objects+=("$obj");; esac
done
xcrun clang -fobjc-arc -fmodules -Wno-nullability-completeness -target arm64-apple-macosx15.0 \
    -I native -I vendor/ImageOptim/imageoptim -I vendor/ImageOptim/imageoptim/Backend \
    -c tests/FailureJob.m -o build/FailureJob.o
objects+=("$PWD/build/FailureJob.o")
xcrun swiftc -swift-version 5 -Onone -g -target arm64-apple-macosx15.0 \
    -import-objc-header tests/Checks-Bridging-Header.h \
    -I native -I vendor/ImageOptim/imageoptim -I vendor/ImageOptim/imageoptim/Backend \
    -framework Cocoa -framework ImageIO -lz -lsqlite3 \
    native/PhotoCore.swift native/WorkbenchModel.swift tests/NativeChecks.swift "${objects[@]}" \
    -o "$check_app/Contents/MacOS/NativeChecks"
codesign --force --sign - "$check_app" >/dev/null 2>&1
"$check_app/Contents/MacOS/NativeChecks" "$PWD/build/fixtures"
