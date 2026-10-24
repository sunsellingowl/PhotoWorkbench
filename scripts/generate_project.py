"""Generate the dependency-free Xcode project from the pinned sources (stdlib only)."""
from pathlib import Path
import hashlib, json
ROOT = Path(__file__).resolve().parents[1]
objects = {}
def ident(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def add(name, text):
    key = ident(name); objects[key] = text; return key
def quote(s): return json.dumps(str(s))
def array(items): return '(' + ', '.join(items) + ')'
source_paths = sorted(str(p.relative_to(ROOT)) for p in (ROOT/'native').glob('*.swift'))
source_paths += sorted(str(p.relative_to(ROOT)) for p in (ROOT/'native').glob('*.m'))
base = 'vendor/ImageOptim/imageoptim/'
source_paths += [base + 'Backend/' + p + '.m' for p in ['Job','JobQueue','File','TempFile']]
source_paths += [base + 'ResultsDb.m']
source_paths += sorted(str(p.relative_to(ROOT)) for p in (ROOT/base/'Backend/Workers').glob('*.m'))
source_paths += ['vendor/libpng/' + name + '.c' for name in ['png','pngerror','pngget','pngmem','pngpread','pngread','pngrio','pngrtran','pngrutil','pngset','pngtrans','pngwio','pngwrite','pngwtran','pngwutil']]
files=[]; sources=[]
for path in source_paths:
    typ = 'sourcecode.swift' if path.endswith('.swift') else 'sourcecode.c.objc' if path.endswith('.m') else 'sourcecode.c.c'
    ref=add(path, f'{{isa = PBXFileReference; lastKnownFileType = {typ}; path = {quote(path)}; sourceTree = SOURCE_ROOT; }}')
    files.append(ref)
    sources.append(add('compile '+path, f'{{isa = PBXBuildFile; fileRef = {ref}; }}'))
app=add('product', '{isa = PBXFileReference; explicitFileType = wrapper.application; path = PhotoWorkbench.app; sourceTree = BUILT_PRODUCTS_DIR; }')
products=add('products', '{isa = PBXGroup; name = Products; children = ('+app+'); sourceTree = "<group>"; }')
group=add('root', '{isa = PBXGroup; children = '+array(files+[products])+'; sourceTree = "<group>"; }')
phase=add('sources', '{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = '+array(sources)+'; runOnlyForDeploymentPostprocessing = 0; }')
resources=add('resources', '{isa = PBXShellScriptBuildPhase; buildActionMask = 2147483647; files = (); inputPaths = (); outputPaths = (); alwaysOutOfDate = 1; runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/bash; shellScript = '+quote('set -eu\nbash "$SRCROOT/scripts/bundle_resources.sh" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"')+'; }')
settings = {
 'PRODUCT_NAME':'PhotoWorkbench', 'PRODUCT_BUNDLE_IDENTIFIER':'local.cc.PhotoWorkbench',
 'INFOPLIST_FILE':'native/Info.plist','SWIFT_VERSION':'5.0','MACOSX_DEPLOYMENT_TARGET':'15.0',
 'SDKROOT':'macosx', 'ARCHS':'arm64','ONLY_ACTIVE_ARCH':'YES',
 'CLANG_ENABLE_OBJC_ARC':'YES','CLANG_ENABLE_MODULES':'YES', 'ENABLE_USER_SCRIPT_SANDBOXING':'NO',
 'CODE_SIGN_IDENTITY':'-', 'CODE_SIGN_STYLE':'Manual', 'ENABLE_HARDENED_RUNTIME':'NO',
 'SWIFT_OBJC_BRIDGING_HEADER':'native/PhotoWorkbench-Bridging-Header.h',
 'HEADER_SEARCH_PATHS':['$(SRCROOT)/native','$(SRCROOT)/vendor/ImageOptim/imageoptim','$(SRCROOT)/vendor/ImageOptim/imageoptim/Backend','$(SRCROOT)/vendor/libpng'],
 'GCC_PREPROCESSOR_DEFINITIONS':['PNG_ARM_NEON_OPT=0'],
 'OTHER_CFLAGS':['-Wno-deprecated-declarations','-Wno-incompatible-pointer-types'],
 'OTHER_LDFLAGS':['-framework','Cocoa','-framework','ImageIO','-framework','QuickLookUI','-lz','-lsqlite3'],
 'SWIFT_OPTIMIZATION_LEVEL':'-O', 'GCC_OPTIMIZATION_LEVEL':'2',
}
def config(name):
    body=' '.join(k+' = '+(array([quote(x) for x in v]) if isinstance(v,list) else quote(v))+';' for k,v in settings.items())
    return add(name, '{isa = XCBuildConfiguration; buildSettings = {'+body+'}; name = '+name+'; }')
configs=add('configs','{isa = XCConfigurationList; buildConfigurations = '+array([config('Debug'),config('Release')])+'; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }')
target=add('target', '{isa = PBXNativeTarget; name = PhotoWorkbench; productName = PhotoWorkbench; productType = "com.apple.product-type.application"; productReference = '+app+'; buildConfigurationList = '+configs+'; buildPhases = '+array([phase,resources])+'; buildRules = (); dependencies = (); }')
project=add('project', '{isa = PBXProject; attributes = {LastUpgradeCheck = 2700; }; buildConfigurationList = '+configs+'; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en, Base); mainGroup = '+group+'; productRefGroup = '+products+'; projectDirPath = ""; projectRoot = ""; targets = ('+target+'); }')
folder=ROOT/'PhotoWorkbench.xcodeproj'; folder.mkdir(exist_ok=True)
(folder/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+ '\n'.join(k+' = '+v+';' for k,v in objects.items())+'\n}; rootObject = '+project+'; }\n')
