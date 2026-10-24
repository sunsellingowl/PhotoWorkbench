"""Fetch locked inputs once; verify cached inputs without network on every build."""
import hashlib, json, os, plistlib, shutil, subprocess, sys, tarfile, zipfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
LOCK = json.loads((ROOT/'dependencies.lock.json').read_text())
VENDOR = ROOT/'vendor'
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def require(ok, message):
    if not ok: raise SystemExit(message)
def run(*args, **kw): return subprocess.run(args, check=True, **kw)
def archive(name, ext):
    spec=LOCK[name]; path=ROOT/'build/downloads'/(name+ext)
    path.parent.mkdir(parents=True,exist_ok=True)
    if not path.exists():
        temp=path.with_suffix(path.suffix+'.partial')
        run('curl','--fail','--location','--retry','2','--max-time','180',spec['url'],'-o',str(temp))
        require(digest(temp)==spec['sha256'],f'{name}: downloaded checksum mismatch')
        temp.rename(path)
    require(digest(path)==spec['sha256'],f'{name}: cached checksum mismatch')
    return path

def verify():
    stamp=VENDOR/'.prepared'
    require(stamp.exists(),'Dependencies are missing. Run bash run_prepare.sh.')
    record=json.loads(stamp.read_text())
    require(record['lock']==digest(ROOT/'dependencies.lock.json'),'Dependency lock changed; run run_prepare.sh again.')
    require(record['patch']==digest(ROOT/'patches/imageoptim.patch'),'Source patch changed; re-prepare from clean vendor/ImageOptim.')
    for name, expected in LOCK['patchedSourceSha256'].items():
        require(digest(VENDOR/'ImageOptim'/name)==expected, f'Upstream patch not applied correctly: {name}')
    for name, expected in record['files'].items():
        path=VENDOR/name
        require(path.is_file() and digest(path)==expected, f'Dependency changed or missing: {path}')
    print('Pinned sources, notices and engine checksums verified.')

if '--verify' in sys.argv:
    verify(); sys.exit()
if (VENDOR/'.prepared').exists():
    verify(); sys.exit()
VENDOR.mkdir(exist_ok=True)
for name, folder in [('imageoptim','ImageOptim'),('libpng','libpng')]:
    dest=VENDOR/folder
    if not dest.exists():
        dest.mkdir()
        path=archive(name,'.tar.gz')
        # Extract only ordinary files/directories, under the single upstream root.
        with tarfile.open(path) as tar:
            for entry in tar:
                parts=Path(entry.name).parts[1:]
                if not parts or entry.issym() or entry.islnk(): continue
                require('..' not in parts and not Path(*parts).is_absolute(),'Unsafe archive path')
                target=dest.joinpath(*parts)
                if entry.isdir(): target.mkdir(parents=True,exist_ok=True)
                elif entry.isfile():
                    target.parent.mkdir(parents=True,exist_ok=True)
                    with tar.extractfile(entry) as src, target.open('wb') as out: shutil.copyfileobj(src,out)
                    target.chmod(entry.mode & 0o777)
patch=ROOT/'patches/imageoptim.patch'
reverse=subprocess.run(['patch','--dry-run','--force','-R','-p1','-i',str(patch)],cwd=VENDOR/'ImageOptim',stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
if reverse.returncode: run('patch','--batch','--forward','-p1','-i',str(patch),cwd=VENDOR/'ImageOptim')
shutil.copyfile(VENDOR/'libpng/scripts/pnglibconf.h.prebuilt',VENDOR/'libpng/pnglibconf.h')
engines=VENDOR/'Engines'; notices=VENDOR/'Notices'
engines.mkdir(exist_ok=True); notices.mkdir(exist_ok=True)
app=Path(os.environ.get('IMAGEOPTIM_APP','/Applications/ImageOptim.app'))
needed=[name for name in LOCK['engines']['files'] if name!='pngout' and not (engines/name).exists()]
if needed:
    with (app/'Contents/Info.plist').open('rb') as f: version=plistlib.load(f)['CFBundleShortVersionString']
    require(version==LOCK['engines']['imageoptimAppVersion'],'Installed ImageOptim version differs from the lock; do not silently upgrade engines.')
    source=app/'Contents/Frameworks/ImageOptimGPL.framework/Versions/A/Resources'
    for name in needed: shutil.copy2(source/name,engines/name)
if not (engines/'pngout').exists() or not (notices/'PNGOUT.txt').exists():
    with zipfile.ZipFile(archive('pngout','.zip')) as z:
        (engines/'pngout').write_bytes(z.read('pngout-20230322-mac/pngout'))
        (notices/'PNGOUT.txt').write_bytes(z.read('pngout-20230322-mac/readme.txt'))
shutil.copyfile(VENDOR/'libpng/LICENSE',notices/'libpng-LICENSE.txt')
shutil.copyfile(VENDOR/'ImageOptim/LICENSE',notices/'ImageOptim-LICENSE.txt')
if not (notices/'ImageOptim-Credits.html').exists(): shutil.copyfile(app/'Contents/Resources/en.lproj/Credits.html',notices/'ImageOptim-Credits.html')
for name, expected in LOCK['engines']['files'].items():
    path=engines/name; require(digest(path)==expected,f'Engine checksum mismatch: {name}'); path.chmod(0o755)
    run('lipo','-verify_arch','arm64',str(path))
    deps=subprocess.check_output(['otool','-L',str(path)],text=True)
    for line in deps.splitlines():
        if not line.startswith('\t'): continue
        dep=line.strip().split(' (')[0]
        if dep.startswith('@loader_path/'):
            require((engines/Path(dep).name).exists(),f'Missing bundled library: {dep}')
        else: require(dep.startswith(('/usr/lib/','/System/Library/')),f'External library dependency: {dep}')
for source in (ROOT/'licenses').glob('*'):
    if source.is_file(): shutil.copyfile(source,notices/source.name)
for name, expected in LOCK['notices'].items(): require(digest(notices/name)==expected,f'Notice checksum mismatch: {name}')
files={str(p.relative_to(VENDOR)):digest(p) for p in sorted(VENDOR.rglob('*')) if p.is_file() and not any(x.startswith('.') for x in p.relative_to(VENDOR).parts)}
(VENDOR/'.prepared').write_text(json.dumps({'lock':digest(ROOT/'dependencies.lock.json'),'patch':digest(patch),'files':files},indent=2)+'\n')
verify()
