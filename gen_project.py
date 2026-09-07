#!/usr/bin/env python3
"""Генерирует KubeLens.xcodeproj из содержимого Sources/KubeLens. Запускать после добавления файлов."""
import os, uuid

NAME = "KubeLens"
SRC = f"Sources/{NAME}"
BUNDLE = "com.nvsces.kubelens"
TEAM = "DT7W5LCT3Z"

files = sorted(f for f in os.listdir(SRC) if f.endswith(".swift"))

def oid(seed):
    return uuid.uuid5(uuid.NAMESPACE_DNS, "kubelens." + seed).hex[:24].upper()

keys = ["project","target","product","mainGroup","srcGroup","productsGroup","sourcesPhase",
        "resourcesPhase","frameworksPhase","configList","projConfigList","debugCfg","releaseCfg",
        "targetDebug","targetRelease","assets_fr","assets_bf"]
ids = {k: oid(k) for k in keys}

file_refs, build_files, children, sources = [], [], [], []
for f in files:
    fr, bf = oid("fr." + f), oid("bf." + f)
    file_refs.append(f'\t\t{fr} /* {f} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {f}; sourceTree = "<group>"; }};')
    build_files.append(f'\t\t{bf} /* {f} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr} /* {f} */; }};')
    children.append(f'\t\t\t\t{fr} /* {f} */,')
    sources.append(f'\t\t\t\t{bf} /* {f} in Sources */,')

target_settings = f'''				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_IDENTITY = "Apple Development";
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = {TEAM};
				ENABLE_HARDENED_RUNTIME = YES;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = {NAME};
				INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.developer-tools";
				INFOPLIST_KEY_LSUIElement = YES;
				INFOPLIST_KEY_NSHumanReadableCopyright = "";
				INFOPLIST_KEY_NSPrincipalClass = NSApplication;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE};
				PRODUCT_NAME = "$(TARGET_NAME)";
				PROVISIONING_PROFILE_SPECIFIER = "";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
'''

common = '''				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				MACOSX_DEPLOYMENT_TARGET = 14.4;
				SDKROOT = macosx;
'''

pbx = f'''// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 56;
	objects = {{

/* Begin PBXBuildFile section */
{chr(10).join(build_files)}
		{ids["assets_bf"]} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {ids["assets_fr"]} /* Assets.xcassets */; }};
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{chr(10).join(file_refs)}
		{ids["assets_fr"]} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; name = Assets.xcassets; path = Resources/Assets.xcassets; sourceTree = "<group>"; }};
		{ids["product"]} /* {NAME}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {NAME}.app; sourceTree = BUILT_PRODUCTS_DIR; }};
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		{ids["frameworksPhase"]} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{ids["mainGroup"]} = {{
			isa = PBXGroup;
			children = (
				{ids["srcGroup"]} /* {NAME} */,
				{ids["assets_fr"]} /* Assets.xcassets */,
				{ids["productsGroup"]} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{ids["srcGroup"]} /* {NAME} */ = {{
			isa = PBXGroup;
			children = (
{chr(10).join(children)}
			);
			name = {NAME};
			path = {SRC};
			sourceTree = "<group>";
		}};
		{ids["productsGroup"]} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{ids["product"]} /* {NAME}.app */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{ids["target"]} /* {NAME} */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {ids["configList"]};
			buildPhases = (
				{ids["sourcesPhase"]} /* Sources */,
				{ids["frameworksPhase"]} /* Frameworks */,
				{ids["resourcesPhase"]} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = {NAME};
			productName = {NAME};
			productReference = {ids["product"]} /* {NAME}.app */;
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{ids["project"]} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1600;
				LastUpgradeCheck = 1600;
			}};
			buildConfigurationList = {ids["projConfigList"]};
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = ru;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				ru,
				Base,
			);
			mainGroup = {ids["mainGroup"]};
			productRefGroup = {ids["productsGroup"]} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{ids["target"]} /* {NAME} */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{ids["resourcesPhase"]} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{ids["assets_bf"]} /* Assets.xcassets in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{ids["sourcesPhase"]} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{chr(10).join(sources)}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		{ids["debugCfg"]} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{common}				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_TESTABILITY = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
				ONLY_ACTIVE_ARCH = YES;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			}};
			name = Debug;
		}};
		{ids["releaseCfg"]} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{common}				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_OPTIMIZATION_LEVEL = "-O";
			}};
			name = Release;
		}};
		{ids["targetDebug"]} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{target_settings}			}};
			name = Debug;
		}};
		{ids["targetRelease"]} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{target_settings}			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{ids["projConfigList"]} = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{ids["debugCfg"]} /* Debug */,
				{ids["releaseCfg"]} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{ids["configList"]} = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{ids["targetDebug"]} /* Debug */,
				{ids["targetRelease"]} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */
	}};
	rootObject = {ids["project"]} /* Project object */;
}}
'''

os.makedirs(f"{NAME}.xcodeproj/xcshareddata/xcschemes", exist_ok=True)
open(f"{NAME}.xcodeproj/project.pbxproj", "w").write(pbx)
open(f"{NAME}.xcodeproj/xcshareddata/xcschemes/{NAME}.xcscheme", "w").write(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{ids["target"]}" BuildableName = "{NAME}.app" BlueprintName = "{NAME}" ReferencedContainer = "container:{NAME}.xcodeproj"/>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{ids["target"]}" BuildableName = "{NAME}.app" BlueprintName = "{NAME}" ReferencedContainer = "container:{NAME}.xcodeproj"/>
      </BuildableProductRunnable>
   </LaunchAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"/>
</Scheme>
''')
print(f"проект: {len(files)} файлов")
