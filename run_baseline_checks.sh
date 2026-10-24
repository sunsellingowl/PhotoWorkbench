#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bash run_prepare.sh --verify
python_cmd=/Users/cc/opt/miniconda3/envs/mydailypython/bin/python
[[ -x "$python_cmd" ]] || python_cmd=python3
"$python_cmd" tests/make_fixtures.py build/fixtures
"$python_cmd" - <<'PY'
from pathlib import Path
import hashlib,json,subprocess
lock=json.loads(Path('dependencies.lock.json').read_text())
archive=Path('build/downloads/imageoptim.tar.gz')
if not archive.exists():
 archive.parent.mkdir(parents=True,exist_ok=True)
 subprocess.run(['curl','-fL','--retry','2',lock['imageoptim']['url'],'-o',str(archive)],check=True)
assert hashlib.sha256(archive.read_bytes()).hexdigest()==lock['imageoptim']['sha256']
root=Path('build/baseline-source');root.mkdir(parents=True,exist_ok=True)
subprocess.run(['tar','-xzf',str(archive),'-C',str(root),'--strip-components=1'],check=True)
p=root/'imageoptim/Backend/Job.m';p.write_text(p.read_text().replace('#import "ImageOptimController.h"','// UI header unnecessary in the baseline harness.'))
p=root/'imageoptim/Backend/Workers/CommandWorker.m';s=p.read_text();a=s.index('    NSBundle *bundle =',s.index('- (NSString *)pathForExecutableName:'));b=s.index('\n    if (path) {',a)
s=s[:a]+'    NSString *path = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:[@"Engines" stringByAppendingPathComponent:resourceName]];\n'+s[b:];p.write_text(s)
PY
base="$PWD/build/baseline-source/imageoptim"
app="$PWD/build/BaselineChecks.app"
mkdir -p "$app/Contents/MacOS"
cp native/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable BaselineChecks' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.cc.PhotoWorkbench.BaselineChecks' "$app/Contents/Info.plist"
bash scripts/bundle_resources.sh "$app/Contents/Resources"
cp "$base/defaults.plist" "$app/Contents/Resources/"
xcrun clang -O2 -fobjc-arc -fmodules -Wno-deprecated-declarations -Wno-incompatible-pointer-types -target arm64-apple-macosx15.0 \
    -I "$base" -I "$base/Backend" -framework Cocoa -lsqlite3 \
    "$base/Backend/Job.m" "$base/Backend/JobQueue.m" "$base/Backend/File.m" "$base/Backend/TempFile.m" \
    "$base/Backend/Workers/"*.m "$base/ResultsDb.m" tests/BaselineMain.m -o "$app/Contents/MacOS/BaselineChecks"
codesign --force --sign - "$app" >/dev/null 2>&1
output_dir=$(mktemp -d "$PWD/build/baseline-output.XXXXXX")
"$app/Contents/MacOS/BaselineChecks" "$PWD/build/fixtures" "$output_dir"
printf '%s\n' "$output_dir" > build/baseline-latest.txt
