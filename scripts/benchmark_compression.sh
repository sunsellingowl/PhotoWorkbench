#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
object_dir="${1:-$PWD/build/DerivedData/Build/Intermediates.noindex/PhotoWorkbench.build/Release/PhotoWorkbench.build/Objects-normal/arm64}"
mode="${2:-fast}"
bench_app="$PWD/build/CompressionBenchmark.app"
mkdir -p "$bench_app/Contents/MacOS"
cp native/Info.plist "$bench_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable CompressionBenchmark' "$bench_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.cc.PhotoWorkbench.Benchmark' "$bench_app/Contents/Info.plist"
bash scripts/bundle_resources.sh "$bench_app/Contents/Resources"
cp vendor/ImageOptim/imageoptim/defaults.plist "$bench_app/Contents/Resources/"
objects=()
for obj in "$object_dir"/*.o; do
    case "$(basename "$obj")" in ExifDates.o|PhotoCore.o|WorkbenchModel.o|PhotoWorkbenchApp.o) ;; *) objects+=("$obj");; esac
done
xcrun clang -fobjc-arc -fmodules -Wno-nullability-completeness -target arm64-apple-macosx15.0 \
    -I native -I vendor/ImageOptim/imageoptim -I vendor/ImageOptim/imageoptim/Backend \
    tests/CompressionBenchmark.m "${objects[@]}" -framework Cocoa -framework ImageIO -lz -lsqlite3 \
    -o "$bench_app/Contents/MacOS/CompressionBenchmark"
codesign --force --sign - "$bench_app" >/dev/null 2>&1
"$bench_app/Contents/MacOS/CompressionBenchmark" "$PWD/build/fixtures/benchmark.png" "$mode"
