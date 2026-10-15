#!/usr/bin/env python3
"""Deterministic multiplatform project; runtime binaries and models are local."""
from pathlib import Path
import hashlib

ROOT = Path(__file__).resolve().parents[1]
objects = {}
def ident(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def obj(name, body):
    key = ident(name); objects[key] = body; return key
def quoted(value): return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'
def array(values): return '(' + ', '.join(values) + ',)'
def configs(name, settings):
    configs = []
    for mode in ['Debug', 'Release']:
        merged = dict(settings)
        merged['SWIFT_OPTIMIZATION_LEVEL'] = '-Onone' if mode == 'Debug' else '-O'
        merged['DEBUG_INFORMATION_FORMAT'] = 'dwarf' if mode == 'Debug' else 'dwarf-with-dsym'
        if mode == 'Debug':
            merged['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG'
            merged['ONLY_ACTIVE_ARCH'] = 'YES'
        config = obj(name+mode, 'isa = XCBuildConfiguration; name = '+mode+'; buildSettings = {' + ''.join(quoted(k)+' = '+quoted(v)+';' for k,v in merged.items()) + '};')
        configs.append(config)
    return obj(name+'ConfigList', 'isa = XCConfigurationList; buildConfigurations = '+array(configs)+'; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

project_id = ident('Project')
app_paths = sorted((ROOT/'App').rglob('*.swift'))
sources = [obj(str(p.relative_to(ROOT)), 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = '+quoted(p.name)+'; path = '+quoted(str(p.relative_to(ROOT)))+'; sourceTree = SOURCE_ROOT;') for p in app_paths]
ui_path = obj('UITestFile','isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = UITests/InkEngineUITests.swift; sourceTree = SOURCE_ROOT;')
assets = obj('Assets', 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = App/Assets.xcassets; sourceTree = SOURCE_ROOT;')
products, targets, schemes = [], [], []
package = obj('SpeechPackage', 'isa = XCLocalSwiftPackageReference; relativePath = Vendor/SpeechRuntime;')
# A package at the project root was resolved by xcodebuild but appeared as a
# missing InkCore product in the Xcode GUI. Build the same sources as a native
# static library here; Package.swift remains the command-line core test harness.
core_paths = sorted((ROOT/'Sources/InkCore').rglob('*.swift'))
core_sources = [obj('CoreFile'+str(p.relative_to(ROOT)), 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = '+quoted(p.name)+'; path = '+quoted(str(p.relative_to(ROOT)))+'; sourceTree = SOURCE_ROOT;') for p in core_paths]
core_product = obj('InkCoreProduct', 'isa = PBXFileReference; explicitFileType = archive.ar; path = libInkCore.a; sourceTree = BUILT_PRODUCTS_DIR;'); products.append(core_product)
core_builds = [obj('CoreSourceBuild'+src, 'isa = PBXBuildFile; fileRef = '+src+';') for src in core_sources]
core_phase = obj('InkCoreSources', 'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = '+array(core_builds)+'; runOnlyForDeploymentPostprocessing = 0;')
core_config = configs('InkCore', dict(PRODUCT_NAME='InkCore', PRODUCT_MODULE_NAME='InkCore', DEFINES_MODULE='YES', SWIFT_VERSION='5.0', SKIP_INSTALL='YES', SDKROOT='auto', SUPPORTED_PLATFORMS='macosx iphoneos iphonesimulator', MACOSX_DEPLOYMENT_TARGET='26.0', IPHONEOS_DEPLOYMENT_TARGET='26.0', CODE_SIGNING_ALLOWED='NO'))
core_target = obj('InkCore', 'isa = PBXNativeTarget; name = InkCore; productName = InkCore; productType = "com.apple.product-type.library.static"; productReference = '+core_product+'; buildConfigurationList = '+core_config+'; buildPhases = '+array([core_phase])+'; buildRules = (); dependencies = ();'); targets.append(core_target)
speech_resources = obj('SpeechResources', 'isa = PBXFileReference; lastKnownFileType = folder; path = App/Resources/Speech; sourceTree = SOURCE_ROOT;')
speech_mac_resources = obj('SpeechMacResources', 'isa = PBXFileReference; lastKnownFileType = folder; path = App/Resources/SpeechMac; sourceTree = SOURCE_ROOT;')
for platform in ['Universal']:
    name = 'InkEngine'
    target_id = ident(name)
    product = obj(name+'Product','isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "Ink Engine.app"; sourceTree = BUILT_PRODUCTS_DIR;'); products.append(product)
    builds = [obj(name+src, 'isa = PBXBuildFile; fileRef = '+src+';') for src in sources]
    source_phase = obj(name+'Sources','isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = '+array(builds)+'; runOnlyForDeploymentPostprocessing = 0;')
    dependency = obj(name+'Speech', 'isa = XCSwiftPackageProductDependency; package = '+package+'; productName = SpeechRuntime;')
    core_build = obj(name+'CoreBuild','isa = PBXBuildFile; fileRef = '+core_product+';')
    runtime_build = obj(name+'RuntimeBuild','isa = PBXBuildFile; productRef = '+dependency+';')
    frameworks = obj(name+'Frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = '+array([core_build,runtime_build])+'; runOnlyForDeploymentPostprocessing = 0;')
    asset_build = obj(name+'AssetsBuild', 'isa = PBXBuildFile; fileRef = '+assets+';')
    model_build = obj(name+'ModelBuild', 'isa = PBXBuildFile; fileRef = '+speech_resources+';')
    mac_model_build = obj(name+'MacModelBuild', 'isa = PBXBuildFile; fileRef = '+speech_mac_resources+'; platformFilters = (macos,);')
    resource_phase = obj(name+'Resources','isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = '+array([asset_build,model_build,mac_model_build])+'; runOnlyForDeploymentPostprocessing = 0;')
    settings = dict(INK_APP_DISPLAY_NAME='墨语引擎', PRODUCT_NAME='Ink Engine', PRODUCT_BUNDLE_IDENTIFIER='org.ailifelab.InkEngine', INFOPLIST_FILE='Config/InkEngine-Info.plist', SWIFT_VERSION='5.0', CODE_SIGN_STYLE='Automatic', GENERATE_INFOPLIST_FILE='NO', MARKETING_VERSION='0.3.1', CURRENT_PROJECT_VERSION='6', ENABLE_USER_SCRIPT_SANDBOXING='YES', ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon')
    settings.update(SDKROOT='auto', SUPPORTED_PLATFORMS='macosx iphoneos iphonesimulator', MACOSX_DEPLOYMENT_TARGET='26.0', IPHONEOS_DEPLOYMENT_TARGET='26.0', TARGETED_DEVICE_FAMILY='1,2', SUPPORTS_MACCATALYST='NO')
    settings['EXCLUDED_SOURCE_FILE_NAMES[sdk=iphoneos*]'] = 'SpeechMac'
    settings['EXCLUDED_SOURCE_FILE_NAMES[sdk=iphonesimulator*]'] = 'SpeechMac'
    settings['CODE_SIGN_IDENTITY[sdk=macosx*]'] = '-'
    settings['CODE_SIGN_ENTITLEMENTS[sdk=macosx*]'] = 'Config/Mac.entitlements'
    settings['ENABLE_HARDENED_RUNTIME[sdk=macosx*]'] = 'YES'
    settings['DEVELOPMENT_TEAM'] = ''
    settings['CODE_SIGN_IDENTITY[sdk=iphoneos*]'] = 'Apple Development'
    core_proxy = obj(name+'CoreProxy', 'isa = PBXContainerItemProxy; containerPortal = '+project_id+'; proxyType = 1; remoteGlobalIDString = '+core_target+'; remoteInfo = InkCore;')
    core_dep = obj(name+'CoreDependency', 'isa = PBXTargetDependency; target = '+core_target+'; targetProxy = '+core_proxy+';')
    configuration = configs(name,settings)
    obj(name,'isa = PBXNativeTarget; name = '+name+'; productName = "Ink Engine"; productType = "com.apple.product-type.application"; productReference = '+product+'; buildConfigurationList = '+configuration+'; buildPhases = '+array([source_phase,frameworks,resource_phase])+'; buildRules = (); dependencies = '+array([core_dep])+'; packageProductDependencies = '+array([dependency])+';'); targets.append(target_id)
    test_name = name+'UITests'; test_id = ident(test_name)
    test_product = obj(test_name+'Product','isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = '+test_name+'.xctest; sourceTree = BUILT_PRODUCTS_DIR;'); products.append(test_product)
    test_build = obj(test_name+'Build','isa = PBXBuildFile; fileRef = '+ui_path+';')
    test_phase = obj(test_name+'Sources','isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = '+array([test_build])+'; runOnlyForDeploymentPostprocessing = 0;')
    proxy = obj(test_name+'Proxy','isa = PBXContainerItemProxy; containerPortal = '+project_id+'; proxyType = 1; remoteGlobalIDString = '+target_id+'; remoteInfo = '+name+';')
    target_dep = obj(test_name+'Dependency','isa = PBXTargetDependency; target = '+target_id+'; targetProxy = '+proxy+';')
    test_settings = dict(settings)
    test_settings.pop('INFOPLIST_FILE'); test_settings.pop('CODE_SIGN_ENTITLEMENTS[sdk=macosx*]',None)
    test_settings.pop('ASSETCATALOG_COMPILER_APPICON_NAME',None)
    test_settings.update(PRODUCT_NAME=test_name, PRODUCT_BUNDLE_IDENTIFIER='org.ailifelab.'+test_name, GENERATE_INFOPLIST_FILE='YES', TEST_TARGET_NAME=name)
    test_settings['ENABLE_HARDENED_RUNTIME[sdk=macosx*]'] = 'NO'
    test_config = configs(test_name,test_settings)
    obj(test_name,'isa = PBXNativeTarget; name = '+test_name+'; productName = '+test_name+'; productType = "com.apple.product-type.bundle.ui-testing"; productReference = '+test_product+'; buildConfigurationList = '+test_config+'; buildPhases = '+array([test_phase])+'; buildRules = (); dependencies = '+array([target_dep])+';'); targets.append(test_id)
    schemes.append((name,target_id,test_name,test_id))

product_group = obj('Products','isa = PBXGroup; name = Products; children = '+array(products)+'; sourceTree = "<group>";')
# The navigator follows the disk hierarchy. File references stay rooted at the
# project so nested groups cannot duplicate a path during regeneration.
tree = {}
def insert_file(path, reference):
    branch = tree
    for part in path.parts[:-1]: branch = branch.setdefault(part, {})
    branch[path.name] = reference
for path, reference in zip(app_paths, sources): insert_file(path.relative_to(ROOT), reference)
for path, reference in zip(core_paths, core_sources): insert_file(path.relative_to(ROOT), reference)
for path, reference in [(Path('App/Assets.xcassets'), assets), (Path('App/Resources/Speech'), speech_resources), (Path('App/Resources/SpeechMac'), speech_mac_resources), (Path('UITests/InkEngineUITests.swift'), ui_path)]: insert_file(path, reference)
for folder in ['Config', 'Scripts', 'Tests/InkCoreTests']:
    for path in sorted((ROOT/folder).glob('*')):
        if path.is_file() and '.local.' not in path.name and not (path.parent == ROOT/'Docs' and path.name != 'Installation.md') and not (path.parent == ROOT/'Samples' and path.name != '听读校稿示例.md') and path.suffix in ['.swift', '.py', '.sh', '.plist', '.entitlements', '.json']:
            reference = obj('Navigator'+str(path.relative_to(ROOT)), 'isa = PBXFileReference; name = '+quoted(path.name)+'; path = '+quoted(str(path.relative_to(ROOT)))+'; sourceTree = SOURCE_ROOT;')
            insert_file(path.relative_to(ROOT), reference)
for name in ['README.md', 'Package.swift']:
    reference = obj('Navigator'+name, 'isa = PBXFileReference; path = '+quoted(name)+'; sourceTree = SOURCE_ROOT;')
    insert_file(Path(name), reference)
def groups(branch, prefix=''):
    children = []
    for name, value in sorted(branch.items(), key=lambda item: (not isinstance(item[1], dict), item[0])):
        if isinstance(value, dict):
            path = prefix+'/'+name if prefix else name
            children.append(obj('Directory:'+path, 'isa = PBXGroup; name = '+quoted(name)+'; children = '+array(groups(value, path))+'; sourceTree = "<group>";'))
        else: children.append(value)
    return children
main_group = obj('MainGroup','isa = PBXGroup; children = '+array(groups(tree)+[product_group])+'; sourceTree = "<group>";')
project_config = configs('Project',dict(CLANG_ENABLE_MODULES='YES', SWIFT_VERSION='5.0', SWIFT_STRICT_CONCURRENCY='targeted'))
attributes = 'LastUpgradeCheck = 2700; TargetAttributes = {'+''.join(test+' = {TestTargetID = '+app+';};' for _,app,_,test in schemes)+'};'
obj('Project','isa = PBXProject; attributes = {'+attributes+'}; buildConfigurationList = '+project_config+'; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh-Hans; hasScannedForEncodings = 0; knownRegions = (en, "zh-Hans", Base); mainGroup = '+main_group+'; productRefGroup = '+product_group+'; projectDirPath = ""; projectRoot = ""; targets = '+array(targets)+'; packageReferences = '+array([package])+';')
project = ROOT/'InkEngine.xcodeproj'; project.mkdir(exist_ok=True)
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+''.join(key+' = {'+value+'};\n' for key,value in objects.items())+'}; rootObject = '+project_id+'; }\n')
scheme_dir = project/'xcshareddata/xcschemes'; scheme_dir.mkdir(parents=True,exist_ok=True)
for name, app, test_name, test in schemes:
    def ref(identifier, target, product): return '<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="'+identifier+'" BuildableName="'+product+'" BlueprintName="'+target+'" ReferencedContainer="container:InkEngine.xcodeproj"/>'
    app_ref=ref(app,name,'Ink Engine.app'); test_ref=ref(test,test_name,test_name+'.xctest')
    (scheme_dir/(name+'.xcscheme')).write_text('<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="2700" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">'+app_ref+'</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">'+test_ref+'</TestableReference></Testables></TestAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">'+app_ref+'</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES"><BuildableProductRunnable runnableDebuggingMode="0">'+app_ref+'</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>')
print('Generated InkEngine.xcodeproj (one multiplatform app + UI tests)')
