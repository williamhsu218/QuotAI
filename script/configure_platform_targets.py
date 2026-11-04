#!/usr/bin/env python3
"""Idempotently register the widget extension and pinned Sparkle dependency."""
from pathlib import Path
import hashlib
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "QuotAI.xcodeproj/project.pbxproj"
subprocess.run(["python3", str(ROOT / "script/sync_xcode_sources.py")], check=True)
text = PROJECT.read_text()
objects = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(PROJECT)]))["objects"]


def uid(label):
    return hashlib.sha1(("QuotAI:platform:" + label).encode()).hexdigest()[:24].upper()


def source_id(path):
    return hashlib.sha1(("QuotAI:file:" + path).encode()).hexdigest()[:24].upper()


def insert(section, identifier, body):
    global text
    if identifier in objects:
        return
    marker = f"/* End {section} section */"
    line = f"\t\t{identifier} = {{{body}}};\n"
    if marker in text:
        text = text.replace(marker, line + marker, 1)
    else:
        marker = "\t};\n\trootObject"
        text = text.replace(marker, f"/* Begin {section} section */\n{line}/* End {section} section */\n" + marker, 1)
    objects[identifier] = {"isa": section}


def append_list(identifier, key, child):
    global text
    pattern = rf"({identifier}\b[^=]*=\s*\{{.*?\b{key}\s*=\s*\()(.*?)(\);)"
    match = re.search(pattern, text, re.S)
    if not match:
        raise ValueError(f"Missing project list {identifier}/{key}")
    if child in match.group(2):
        return
    replacement = match.group(1) + match.group(2) + f" {child}, " + match.group(3)
    text = text[:match.start()] + replacement + text[match.end():]


def update_object(identifier, callback):
    global text
    pattern = rf"({identifier}\b[^=]*=\s*\{{)(.*?)(\}};)"
    match = re.search(pattern, text, re.S)
    if not match:
        raise ValueError(identifier)
    text = text[:match.start()] + match.group(1) + callback(match.group(2)) + match.group(3) + text[match.end():]


package, product = uid("sparkle-package"), uid("sparkle-product")
insert("XCRemoteSwiftPackageReference", package, 'isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/sparkle-project/Sparkle"; requirement = {kind = exactVersion; version = 2.9.6; }; ')
insert("XCSwiftPackageProductDependency", product, f"isa = XCSwiftPackageProductDependency; package = {package}; productName = Sparkle; ")
framework_build = uid("sparkle-framework-build")
insert("PBXBuildFile", framework_build, f"isa = PBXBuildFile; productRef = {product}; ")
append_list("300000000000000000000002", "files", framework_build)
app_target = "200000000000000000000001"
if "packageProductDependencies" not in objects[app_target]:
    update_object(app_target, lambda body: body.replace("productType =", f"packageProductDependencies = ({product}, ); productType ="))
project_id = "100000000000000000000001"
if "packageReferences" not in objects[project_id]:
    text = text.replace('projectRoot = "";', f'projectRoot = "";\n\t\t\tpackageReferences = ({package}, );', 1)

widget_target, widget_product = uid("widget-target"), uid("widget-product")
insert("PBXFileReference", widget_product, 'isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = QuotAIWidget.appex; sourceTree = BUILT_PRODUCTS_DIR; ')
append_list("800000000000000000000009", "children", widget_product)
widget_group = uid("widget-group")
insert("PBXGroup", widget_group, 'isa = PBXGroup; children = (); path = Widgets; sourceTree = "<group>"; ')
append_list("800000000000000000000001", "children", widget_group)
widget_source = uid("widget-source-file")
for name, kind, identifier in [("QuotAIWidget.swift", "sourcecode.swift", widget_source), ("Info.plist", "text.plist.xml", uid("widget-info")), ("QuotAIWidget.entitlements", "text.plist.entitlements", uid("widget-entitlements"))]:
    insert("PBXFileReference", identifier, f'isa = PBXFileReference; lastKnownFileType = {kind}; path = "{name}"; sourceTree = "<group>"; ')
    append_list(widget_group, "children", identifier)

widget_sources = []
intent_source = uid("widget-configuration-file")
insert("PBXFileReference", intent_source, 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "QuotaWidgetConfiguration.swift"; sourceTree = "<group>"; ')
append_list(widget_group, "children", intent_source)
for label, file_id in [("main", widget_source), ("configuration", intent_source), ("content", source_id("App/Views/WidgetQuotaContent.swift")), ("snapshot", source_id("Core/Widget/SharedWidgetSnapshot.swift")), ("storage", source_id("Core/Features/PrivateJSONFile.swift")), ("localization", "900000000000000000000017")]:
    build_id = uid("widget-build-" + label)
    insert("PBXBuildFile", build_id, f"isa = PBXBuildFile; fileRef = {file_id}; ")
    widget_sources.append(build_id)
sources_phase, frameworks_phase, resources_phase = uid("widget-sources"), uid("widget-frameworks"), uid("widget-resources")
insert("PBXSourcesBuildPhase", sources_phase, f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({', '.join(widget_sources)}, ); runOnlyForDeploymentPostprocessing = 0; ")
for build_id in widget_sources:
    append_list(sources_phase, "files", build_id)
insert("PBXFrameworksBuildPhase", frameworks_phase, "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; ")
locale_build = uid("widget-locale-build")
insert("PBXBuildFile", locale_build, "isa = PBXBuildFile; fileRef = 80000000000000000000000A; ")
insert("PBXResourcesBuildPhase", resources_phase, f"isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({locale_build}, ); runOnlyForDeploymentPostprocessing = 0; ")

# Provider marks are shared by the native app and the WidgetKit extension.
provider_assets_group = uid("provider-assets-group")
insert("PBXGroup", provider_assets_group, 'isa = PBXGroup; children = (); path = ProviderAssets; sourceTree = "<group>"; ')
append_list(widget_group, "children", provider_assets_group)
for name in ["CodexProviderMark.png", "ClaudeProviderMark.png", "AntigravityProviderMark.png"]:
    file_id = uid("provider-asset-" + name)
    insert("PBXFileReference", file_id, f'isa = PBXFileReference; lastKnownFileType = image.png; path = "{name}"; sourceTree = "<group>"; ')
    append_list(provider_assets_group, "children", file_id)
    for target, phase in [("app", "300000000000000000000003"), ("widget", resources_phase)]:
        build_id = uid(target + "-provider-asset-" + name)
        insert("PBXBuildFile", build_id, f"isa = PBXBuildFile; fileRef = {file_id}; ")
        append_list(phase, "files", build_id)

configurations = []
for configuration in ["Debug", "Release"]:
    identifier = uid("widget-" + configuration)
    configurations.append(identifier)
    settings = {
        "APPLICATION_EXTENSION_API_ONLY": "YES", "CODE_SIGN_STYLE": "Automatic",
        "CODE_SIGN_ENTITLEMENTS": "Widgets/QuotAIWidget.entitlements", "CURRENT_PROJECT_VERSION": "60",
        "ENABLE_APP_SANDBOX": "YES", "ENABLE_HARDENED_RUNTIME": "YES", "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "Widgets/Info.plist", "MACOSX_DEPLOYMENT_TARGET": "14.0", "MARKETING_VERSION": "3.0.3",
        "PRODUCT_BUNDLE_IDENTIFIER": "$(QUOTAI_APP_BUNDLE_ID).QuotaWidget", "PRODUCT_NAME": "QuotAIWidget", "SKIP_INSTALL": "YES",
        "SWIFT_STRICT_CONCURRENCY": "complete", "SWIFT_VERSION": "6.0", "QUOTAI_APP_BUNDLE_ID": "com.willhsu.QuotAI",
        "QUOTAI_APP_GROUP": "$(DEVELOPMENT_TEAM).com.willhsu.QuotAI", "QUOTAI_URL_SCHEME": "quotai", "QUOTAI_DISPLAY_NAME": "QuotAI",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks @executable_path/../../../../Frameworks",
    }
    content = " ".join(f'{key} = "{value}";' for key, value in settings.items())
    insert("XCBuildConfiguration", identifier, f"isa = XCBuildConfiguration; buildSettings = {{{content}}}; name = {configuration}; ")
configuration_list = uid("widget-configurations")
insert("XCConfigurationList", configuration_list, f"isa = XCConfigurationList; buildConfigurations = ({', '.join(configurations)}, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; ")
insert("PBXNativeTarget", widget_target, f'isa = PBXNativeTarget; buildConfigurationList = {configuration_list}; buildPhases = ({sources_phase}, {frameworks_phase}, {resources_phase}, ); buildRules = (); dependencies = (); name = QuotAIWidget; productName = QuotAIWidget; productReference = {widget_product}; productType = "com.apple.product-type.app-extension"; ')
append_list(project_id, "targets", widget_target)
proxy, dependency = uid("widget-proxy"), uid("widget-dependency")
insert("PBXContainerItemProxy", proxy, f"isa = PBXContainerItemProxy; containerPortal = {project_id}; proxyType = 1; remoteGlobalIDString = {widget_target}; remoteInfo = QuotAIWidget; ")
insert("PBXTargetDependency", dependency, f"isa = PBXTargetDependency; target = {widget_target}; targetProxy = {proxy}; ")
append_list(app_target, "dependencies", dependency)
embed, embed_build = uid("widget-embed"), uid("widget-embed-build")
insert("PBXBuildFile", embed_build, f"isa = PBXBuildFile; fileRef = {widget_product}; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; ")
insert("PBXCopyFilesBuildPhase", embed, f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = ({embed_build}, ); name = "Embed App Extensions"; runOnlyForDeploymentPostprocessing = 0; ')
append_list(app_target, "buildPhases", embed)

# App build settings have nested dictionaries; make their small edits directly.
text = text.replace("PRODUCT_BUNDLE_IDENTIFIER = com.willhsu.QuotAI;", 'PRODUCT_BUNDLE_IDENTIFIER = "$(QUOTAI_APP_BUNDLE_ID)";')
needle = "INFOPLIST_FILE = App/Info.plist;"
if "CODE_SIGN_ENTITLEMENTS = App/QuotAI.entitlements;" not in text:
    text = text.replace(needle, needle + '\n\t\t\t\tCODE_SIGN_ENTITLEMENTS = App/QuotAI.entitlements;\n\t\t\t\tQUOTAI_APP_BUNDLE_ID = com.willhsu.QuotAI;\n\t\t\t\tQUOTAI_APP_GROUP = "$(DEVELOPMENT_TEAM).com.willhsu.QuotAI";\n\t\t\t\tQUOTAI_URL_SCHEME = quotai;\n\t\t\t\tQUOTAI_DISPLAY_NAME = QuotAI;')
PROJECT.write_text("\n".join(line.rstrip() for line in text.splitlines()) + "\n")
subprocess.run(["plutil", "-lint", str(PROJECT)], check=True)
print("Widget extension and Sparkle 2.9.6 are configured.")
