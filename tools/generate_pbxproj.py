#!/usr/bin/env python3
"""Emit HiMarkDown.xcodeproj/project.pbxproj for a minimal macOS SwiftUI app."""
import uuid


def uid() -> str:
    return uuid.uuid4().hex[:24]


# Fixed root IDs for stability across regen (optional)
PROJ = uid()
TARGET = uid()
PROJ_CFG_LIST = uid()
TGT_CFG_LIST = uid()
SOURCES = uid()
RESOURCES = uid()
FRAMEWORKS = uid()
GROUP = uid()
PRODUCTS = uid()
APP_REF = uid()
ENTITLEMENTS = uid()
INFOPLIST = uid()

swift_files = [
    "HiMarkDownApp.swift",
    "DocumentModel.swift",
    "ContentView.swift",
    "MarkdownEditorView.swift",
    "MarkdownHighlighter.swift",
    "WebEditorView.swift",
    "HeadingParser.swift",
    "SettingsAndFind.swift",
    "OutlineSidebar.swift",
    "HiAppearance.swift",
]

file_ids = {name: uid() for name in swift_files}
build_file_ids = {name: uid() for name in swift_files}

WEB_FOLDER = uid()
WEB_FOLDER_BF = uid()
ASSETS = uid()
ASSETS_BF = uid()

pbx = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 56;
	objects = {{

/* Begin PBXBuildFile section */
"""
for name in swift_files:
    pbx += f"\t\t{build_file_ids[name]} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ids[name]} /* {name} */; }};\n"
pbx += f"\t\t{WEB_FOLDER_BF} /* Web in Resources */ = {{isa = PBXBuildFile; fileRef = {WEB_FOLDER} /* Web */; }};\n"
pbx += f"\t\t{ASSETS_BF} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {ASSETS} /* Assets.xcassets */; }};\n"
pbx += """/* End PBXBuildFile section */

/* Begin PBXFileReference section */
"""
pbx += f"\t\t{APP_REF} /* HiMarkDown.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = HiMarkDown.app; sourceTree = BUILT_PRODUCTS_DIR; }};\n"
for name in swift_files:
    pbx += f"\t\t{file_ids[name]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};\n"
pbx += f"\t\t{ENTITLEMENTS} /* HiMarkDown.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = HiMarkDown.entitlements; sourceTree = \"<group>\"; }};\n"
pbx += f"\t\t{INFOPLIST} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};\n"
pbx += f"\t\t{WEB_FOLDER} /* Web */ = {{isa = PBXFileReference; lastKnownFileType = folder; path = Web; sourceTree = \"<group>\"; }};\n"
pbx += f"\t\t{ASSETS} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = \"<group>\"; }};\n"
pbx += """/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
"""
pbx += f"\t\t{FRAMEWORKS} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n"
pbx += """/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
"""
children = "\n".join([f"\t\t\t\t{file_ids[n]} /* {n} */," for n in swift_files])
pbx += f"\t\t{GROUP} /* HiMarkDown */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{children}\n\t\t\t\t{ENTITLEMENTS} /* HiMarkDown.entitlements */,\n\t\t\t\t{INFOPLIST} /* Info.plist */,\n\t\t\t\t{WEB_FOLDER} /* Web */,\n\t\t\t\t{ASSETS} /* Assets.xcassets */,\n\t\t\t);\n\t\t\tpath = HiMarkDown;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n"
pbx += f"\t\t{PRODUCTS} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{APP_REF} /* HiMarkDown.app */,\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n"
ROOT = uid()
pbx += f"\t\t{ROOT} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{GROUP} /* HiMarkDown */,\n\t\t\t\t{PRODUCTS} /* Products */,\n\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n"
pbx += """/* End PBXGroup section */

/* Begin PBXNativeTarget section */
"""
pbx += f"\t\t{TARGET} /* HiMarkDown */ = {{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {TGT_CFG_LIST} /* Build configuration list for PBXNativeTarget \"HiMarkDown\" */;\n\t\t\tbuildPhases = (\n\t\t\t\t{SOURCES} /* Sources */,\n\t\t\t\t{FRAMEWORKS} /* Frameworks */,\n\t\t\t\t{RESOURCES} /* Resources */,\n\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = HiMarkDown;\n\t\t\tproductName = HiMarkDown;\n\t\t\tproductReference = {APP_REF} /* HiMarkDown.app */;\n\t\t\tproductType = \"com.apple.product-type.application\";\n\t\t}};\n"
pbx += """/* End PBXNativeTarget section */

/* Begin PBXProject section */
"""
pbx += f"\t\t{PROJ} /* Project object */ = {{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {{LastSwiftUpdateCheck = 1500; LastUpgradeCheck = 1500;}};\n\t\t\tbuildConfigurationList = {PROJ_CFG_LIST} /* Build configuration list for PBXProject \"HiMarkDown\" */;\n\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (en, Base);\n\t\t\tmainGroup = {ROOT};\n\t\t\tproductRefGroup = {PRODUCTS} /* Products */;\n\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n\t\t\ttargets = (\n\t\t\t\t{TARGET} /* HiMarkDown */,\n\t\t\t);\n\t\t}};\n"
pbx += """/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
"""
pbx += f"\t\t{RESOURCES} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t\t{WEB_FOLDER_BF} /* Web in Resources */,\n\t\t\t\t{ASSETS_BF} /* Assets.xcassets in Resources */,\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n"
pbx += """/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
"""
pbx += f"\t\t{SOURCES} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n"
for name in swift_files:
    pbx += f"\t\t\t\t{build_file_ids[name]} /* {name} in Sources */,\n"
pbx += f"""\t\t\t);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
"""
DBG_PROJ = uid()
REL_PROJ = uid()
DBG_TGT = uid()
REL_TGT = uid()

common_target = f"""
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_ENTITLEMENTS = HiMarkDown/HiMarkDown.entitlements;
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				ENABLE_APP_SANDBOX = YES;
				ENABLE_HARDENED_RUNTIME = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = HiMarkDown/Info.plist;
				INFOPLIST_KEY_CFBundleDisplayName = HiMarkDown;
				INFOPLIST_KEY_LSApplicationCategoryType = public.app-category.productivity;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MACOSX_DEPLOYMENT_TARGET = 13.0;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = dev.himarkdown.HiMarkDown;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
"""

pbx += f"\t\t{DBG_PROJ} /* Debug */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;\n\t\t\t\tCLANG_ENABLE_MODULES = YES;\n\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;\n\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;\n\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;\n\t\t\t\tONLY_ACTIVE_ARCH = YES;\n\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;\n\t\t\t}};\n\t\t\tname = Debug;\n\t\t}};\n"
pbx += f"\t\t{REL_PROJ} /* Release */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;\n\t\t\t\tCLANG_ENABLE_MODULES = YES;\n\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;\n\t\t\t\tDEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";\n\t\t\t}};\n\t\t\tname = Release;\n\t\t}};\n"

pbx += f"\t\t{DBG_TGT} /* Debug */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{{common_target}\n\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-Onone\";\n\t\t\t}};\n\t\t\tname = Debug;\n\t\t}};\n"
pbx += f"\t\t{REL_TGT} /* Release */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{{common_target}\n\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;\n\t\t\t}};\n\t\t\tname = Release;\n\t\t}};\n"
pbx += """/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
"""
pbx += f"\t\t{PROJ_CFG_LIST} /* Build configuration list for PBXProject \"HiMarkDown\" */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{DBG_PROJ} /* Debug */,\n\t\t\t\t{REL_PROJ} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n"
pbx += f"\t\t{TGT_CFG_LIST} /* Build configuration list for PBXNativeTarget \"HiMarkDown\" */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{DBG_TGT} /* Debug */,\n\t\t\t\t{REL_TGT} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n"
pbx += """/* End XCConfigurationList section */
	};
	rootObject = """ + PROJ + """ /* Project object */;
}
"""

import os

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
proj_dir = os.path.join(root, "HiMarkDown.xcodeproj")
os.makedirs(proj_dir, exist_ok=True)
out = os.path.join(proj_dir, "project.pbxproj")
with open(out, "w", encoding="utf-8") as f:
    f.write(pbx)
print("Wrote", out)
