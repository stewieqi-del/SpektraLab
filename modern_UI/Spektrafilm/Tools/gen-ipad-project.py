#!/usr/bin/env python3
"""Generate SpektraPad.xcodeproj/project.pbxproj from the filesystem.

    Tools/gen-ipad-project.py            # write
    Tools/gen-ipad-project.py --check    # exit 1 if the checked-in file is stale

**This is a fork of `Tools/gen-project.py`, not a shared generator.** The two
projects differ in target, SDK, product and file set, and a generator with two
modes is a generator whose macOS output nobody dares change. `gen-project.py`
still owns `Spektrafilm.xcodeproj` byte for byte -- it scans only
`Spektrafilm/`, so the iPad sources under `SpektraPad/` never enter the Mac
project and the Mac project never needs regenerating because of this one.

What it builds: **SpektraPad**, an iPadOS application that compiles

  * every Swift file under `SpektraPad/` (the shell: app entry, canvas,
    panels, export, import, boot),
  * every Swift file under `Spektrafilm/` **except** the macOS-only ones listed
    in `EXCLUDED` below -- the model, the engine client, the renderer, the
    panels, the controls and the export writer are the same files the Mac app
    compiles, with `#if canImport(AppKit)` arms added where AppKit was used,
  * every C++ translation unit of `engine/src/` that the Mac target compiles
    (same `engine_sources()` rule: no `io/` or `desktop/`, no Vulkan),
  * `SpektraPadResources/Resources` as a folder reference, which is what puts
    `Resources/engine/spektrafilm_constants.bin` in the bundle -- the path
    `EngineClient.defaultResources()` looks for.

The engine's Metal kernels are **not** compiled here. `engine/build.sh ipad`
stamps them for iPadOS and stages them into `SpektraPadResources/Resources/
engine/`, for the same reason the Mac does it outside Xcode: this target sets
`MTL_FAST_MATH = YES` for its own canvas shader and the engine's kernels must
not inherit it (RFC-014 §5.1 trap 1). The pre-build phase below fails the build
if the resources were never staged.

There is no test target. The upstream tests are macOS tests: they instantiate
`NSView`s, snapshot with AppKit and run `xcodebuild test` against a Mac. A Pad
test target that compiled none of that would test a different thing, so it is
not pretended here; `PORT-IPAD.md` says what a Pad test target would need.
"""
from __future__ import annotations

import hashlib
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT.parents[1] / "engine"
SHARED = ROOT / "Spektrafilm"
PAD = ROOT / "SpektraPad"
RESOURCES = ROOT / "SpektraPadResources" / "Resources"

# The target is `SpektraPad` and the product is `SpektraPad.app`. The product
# name is **not** `SpektraLab`: the upstream trademark notice asks that forks
# may study, modify and redistribute the code and data but not ship under its
# name or icon. A published build of this port must have its own name, and the
# cheapest moment to get that right is the first line of the generator.
APP = "SpektraPad"
PRODUCT_NAME = "SpektraPad"
BUNDLE_ID = "com.hanze.filmify.pad"
IPADOS = "17.0"

# The iPad build is its own version line. It is not 1.3.4: a Pad build is a
# port of that release, will diverge where the interface had to change, and a
# version number that matched the Mac's would claim a parity the port does not
# have yet.
MARKETING_VERSION = "0.1.0"
BUILD_NUMBER = "1"

TEAM_ID = os.environ.get("SPEKTRAFILM_PAD_TEAM_ID", "")

# What the Mac app compiles and the Pad must not. Each entry is a decision:
#
#   Windows/           the Mac window chrome -- NSWindow controllers, traffic
#                      lights, the boot window, the settings and about windows,
#                      the key guard. The Pad has its own window-shaped views.
#   Agent/             the CLI and MCP server. Both are macOS host processes;
#                      iPadOS has no `Process` to spawn and no filesystem a
#                      shell could address.
#   Updates/           the Sparkle-shaped update check, a download-and-relaunch
#                      flow the App Store does not allow.
#   SpektrafilmApp.swift      the @main App with `Window` scenes and menus.
#   Canvas/MetalCanvasView.swift  the NSViewRepresentable canvas. `PadCanvas`
#                      is the same interaction model in a `UIView`.
#   Export/ExportPage.swift   1956 lines of Mac export sheet: `NSSavePanel`,
#                      `NSPasteboard`, drag-out. The Pad has `PadExport`.
#   Resources/         the Mac app's own resource folder. The Pad's is
#                      `SpektraPadResources/Resources`, staged by
#                      `engine/build.sh ipad`.
#   SpektraLab.icon    the Icon Composer document. iOS has no such asset type
#                      (`folder.iconcomposer.icon` is a macOS-only file type),
#                      and the icon is the upstream author's trademark besides
#                      -- a published port needs its own. See PORT-IOS.md.
EXCLUDED_DIRS = {"Windows", "Agent", "Updates", "Resources"}
EXCLUDED_FILES = {"SpektrafilmApp.swift",
                  "Canvas/MetalCanvasView.swift",
                  "Export/ExportPage.swift",
                  "SpektraLab.icon"}


def uid(key: str) -> str:
    return hashlib.sha1(key.encode()).hexdigest()[:24].upper()


def relative_to_project(path: Path) -> str:
    """A path spelled relative to the .xcodeproj's directory.

    Ids go through here as well as paths: an absolute path would make every
    object id a function of where the checkout lives, and two checkouts would
    conflict over a change neither had made. Same rule, same reason as
    `Tools/gen-project.py`.
    """
    return Path(os.path.relpath(path, ROOT)).as_posix()


def engine_sources() -> list[Path]:
    """The iPad engine translation units -- exactly the Mac's list.

    The exclusion rule is lifted verbatim from `gen-project.py`: `io/` and
    `desktop/` are the Windows hosts (LibRaw, native TIFF I/O, a desktop
    controller), and `vulkan_gpu.cpp` / `windows_unported.cpp` are the other
    backend. iPadOS gets the Apple sources the Mac gets, no more.
    """
    windows_dirs = {"io", "desktop"}
    windows_files = {"gpu/vulkan_gpu.cpp", "pipeline/windows_unported.cpp"}
    root = ENGINE / "src"
    return sorted(p for p in root.rglob("*.cpp")
                  if p.relative_to(root).parts[0] not in windows_dirs
                  and p.relative_to(root).as_posix() not in windows_files)


def file_type(p: Path) -> str:
    return {".swift": "sourcecode.swift", ".metal": "sourcecode.metal",
            ".cpp": "sourcecode.cpp.cpp", ".h": "sourcecode.c.h", ".hpp": "sourcecode.cpp.h",
            ".plist": "text.plist.xml", ".entitlements": "text.plist.entitlements",
            ".xcassets": "folder.assetcatalog", ".icon": "folder.iconcomposer.icon",
            ".md": "net.daringfireball.markdown",
            ".py": "text.script.python", ".sh": "text.script.sh"}.get(p.suffix, "folder")


class Project:
    def __init__(self):
        self.objects: list[str] = []

    def add(self, id_: str, body: str, comment: str = ""):
        c = f" /* {comment} */" if comment else ""
        self.objects.append(f"\t\t{id_}{c} = {body};")

    def group(self, dir_: Path, target_files: list[tuple[str, Path]], shared: bool,
              name: str | None = None) -> str:
        """A group for `dir_`, recursing, honouring the exclusion lists.

        `shared` says whether the exclusion lists apply: the Pad's own folder
        is compiled whole, the shared Mac folder is compiled minus the files
        the Pad replaces.
        """
        gid = uid("group:" + relative_to_project(dir_))
        children = []
        for entry in sorted(dir_.iterdir(), key=lambda p: (p.is_file(), p.name.lower())):
            if entry.name.startswith(".") or entry.name.endswith(".xcodeproj"):
                continue
            rel = entry.relative_to(SHARED).as_posix() if shared else ""
            if shared:
                if entry.name in EXCLUDED_DIRS:
                    continue
                if entry.name in EXCLUDED_FILES or rel in EXCLUDED_FILES:
                    continue
            is_folder_ref = (entry.is_dir() and entry.suffix in (".xcassets", ".icon")) \
                or entry.name == "Resources"
            if entry.name in ("build", "DerivedData"):
                continue
            if entry.is_dir() and not is_folder_ref:
                children.append((self.group(entry, target_files, shared), entry.name))
                continue
            fid = uid("file:" + relative_to_project(entry))
            # An asset catalogue and an Icon Composer document are *compiled*
            # folders, so they keep their real file type; only the Pad's staged
            # `Resources` is a plain folder reference (Xcode copies it whole).
            ft = "folder" if entry.name == "Resources" else file_type(entry)
            self.add(fid, f"{{isa = PBXFileReference; lastKnownFileType = {ft}; "
                          f"path = \"{entry.name}\"; sourceTree = \"<group>\"; }}", entry.name)
            children.append((fid, entry.name))
            target_files.append((fid, entry))
        kids = ",\n".join(f"\t\t\t\t{cid} /* {cname} */" for cid, cname in children)
        self.add(gid, f"{{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{kids}\n\t\t\t);\n"
                      f"\t\t\tpath = \"{name or dir_.name}\";\n\t\t\tsourceTree = \"<group>\";\n\t\t}}",
                 name or dir_.name)
        return gid


def build() -> tuple[str, str]:
    """Returns (pbxproj text, scheme text)."""
    p = Project()
    app_files: list[tuple[str, Path]] = []

    pad_group = p.group(PAD, app_files, shared=False)
    shared_group = p.group(SHARED, app_files, shared=True)

    # The engine's translation units, as references outside the project tree.
    engine_files: list[tuple[str, Path]] = []
    engine_children = []
    for src in engine_sources():
        fid = uid("file:engine:" + relative_to_project(src))
        p.add(fid, f"{{isa = PBXFileReference; lastKnownFileType = sourcecode.cpp.cpp; "
                   f"name = \"{src.name}\"; path = \"{relative_to_project(src)}\"; "
                   f"sourceTree = SOURCE_ROOT; }}", src.name)
        engine_children.append((fid, src.name))
        engine_files.append((fid, src))
    engine_group = uid("group:engine")
    kids = ",\n".join(f"\t\t\t\t{cid} /* {cname} */" for cid, cname in engine_children)
    p.add(engine_group, f"{{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{kids}\n\t\t\t);"
                        f"\n\t\t\tname = Engine;\n\t\t\tsourceTree = \"<group>\";\n\t\t}}", "Engine")

    # `SpektraPadResources/Resources`, as one folder reference. Xcode copies a
    # folder reference into the bundle with its own name, so the app answers
    # `Bundle.main/Resources/engine/...` -- the path `EngineClient` looks for,
    # and the same layout the Mac gets under `Contents/Resources`.
    res_id = uid("file:pad-resources")
    p.add(res_id, "{isa = PBXFileReference; lastKnownFileType = folder; "
                  "path = SpektraPadResources/Resources; sourceTree = SOURCE_ROOT; }",
          "Resources")
    res_group = uid("group:pad-resources")
    p.add(res_group, f"{{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{res_id} /* Resources */\n"
                     f"\t\t\t);\n\t\t\tname = PadResources;\n\t\t\tsourceTree = \"<group>\";\n\t\t}}",
          "PadResources")

    app_product = uid("product:app")
    p.add(app_product, f"{{isa = PBXFileReference; explicitFileType = wrapper.application; "
                       f"includeInIndex = 0; path = {PRODUCT_NAME}.app; "
                       f"sourceTree = BUILT_PRODUCTS_DIR; }}", f"{PRODUCT_NAME}.app")
    products = uid("group:products")
    p.add(products, f"{{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{app_product}\n\t\t\t);\n"
                    f"\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}}", "Products")
    main_group = uid("group:main")
    p.add(main_group, f"{{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n"
                      f"\t\t\t\t{pad_group},\n\t\t\t\t{shared_group},\n\t\t\t\t{engine_group},\n"
                      f"\t\t\t\t{res_group},\n\t\t\t\t{products}\n\t\t\t);\n"
                      f"\t\t\tsourceTree = \"<group>\";\n\t\t}}")

    def phase(kind: str, files: list[tuple[str, Path]], pred, tag: str) -> str:
        ids = []
        for fid, path in files:
            if pred(path):
                bid = uid(f"build:{tag}:{relative_to_project(path)}")
                p.add(bid, f"{{isa = PBXBuildFile; fileRef = {fid}; }}", path.name)
                ids.append(f"\t\t\t\t{bid} /* {path.name} */")
        pid = uid(f"phase:{tag}:{kind}")
        p.add(pid, f"{{\n\t\t\tisa = {kind};\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n"
                   + ",\n".join(ids) + "\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}",
              tag)
        return pid

    is_src = lambda q: q.suffix in (".swift", ".metal", ".cpp")
    is_res = lambda q: q.suffix in (".xcassets", ".icon")
    app_sources = phase("PBXSourcesBuildPhase", app_files + engine_files, is_src, "pad-sources")
    # The folder reference cannot go through `phase` (it is not in `app_files`),
    # so the resources phase is written out; one folder reference is all it has.
    app_resources = uid("phase:pad-resources:PBXResourcesBuildPhase")
    p.add(app_resources,
          "{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
          "\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}",
          "pad-resources")
    # The asset catalogue rides as a folder reference too, and there is exactly
    # one (`AccentColor`): the shared app's icon is not part of this product.
    asset_catalogue = phase("PBXResourcesBuildPhase", app_files, is_res, "pad-assets")
    app_frameworks = phase("PBXFrameworksBuildPhase", [], lambda q: False, "pad-frameworks")

    # The engine's build settings. `SRCROOT` is this project's directory, so the
    # `../../engine` paths are the same ones `gen-project.py` writes: both
    # projects sit beside each other under `modern_UI/Spektrafilm/`.
    engine_cfg = {
        "CLANG_CXX_LANGUAGE_STANDARD": '"c++20"',
        "CLANG_CXX_LIBRARY": '"libc++"',
        "GCC_C_LANGUAGE_STANDARD": "c11",
        "HEADER_SEARCH_PATHS": "(\n" + "".join(
            f'\t\t\t\t\t"$(SRCROOT)/../../engine/{sub}",\n'
            for sub in ("include", "src", "src/core", "third_party/metal-cpp")
        ) + "\t\t\t\t)",
        # The bridging header is the *shared* one: the engine's C ABI is the same
        # ABI, and a Pad-only copy would be a second place for it to drift.
        "SWIFT_OBJC_BRIDGING_HEADER": '"Spektrafilm/Service/Spektrafilm-Bridging-Header.h"',
        "OTHER_LDFLAGS": '"-framework Metal -framework QuartzCore -framework CoreText '
                         '-framework CoreGraphics -framework Accelerate"',
        # metal-cpp uses `objc_msgSend` and manages its own retain/release; ARC
        # must not be applied to it. Swift's memory management is not this
        # setting, so the Swift side is unaffected.
        "CLANG_ENABLE_OBJC_ARC": "NO",
    }

    common = {
        **engine_cfg,
        "SWIFT_VERSION": "6.0",
        "SWIFT_STRICT_CONCURRENCY": "complete",
        "IPHONEOS_DEPLOYMENT_TARGET": IPADOS,
        "SDKROOT": "iphoneos",
        # 1,2 = iPhone and iPad. The owner's requirement is an Apple-native
        # interface that adapts to the iPhone and to the foldable, so the same
        # binary ships to both families and `NavigationSplitView` collapses the
        # editor into a push stack on the narrow one. Restricting this to `2`
        # would make that impossible at the signing step, not at the layout
        # step, which is the worst place to discover it.
        "TARGETED_DEVICE_FAMILY": "1,2",
        "SUPPORTS_MACCATALYST": "NO",
        "SUPPORTS_MAC_DESIGNED_FOR_IPHONE": "NO",
        "SUPPORTS_MAC_DESIGNED_FOR_IPAD": "YES",
        "ARCHS": "arm64",
        "ONLY_ACTIVE_ARCH": "YES",
        "CODE_SIGN_STYLE": "Automatic",
        "DEVELOPMENT_TEAM": f'"{TEAM_ID}"',
        "CLANG_ENABLE_MODULES": "YES",
        "MARKETING_VERSION": MARKETING_VERSION,
        "CURRENT_PROJECT_VERSION": BUILD_NUMBER,
        "SWIFT_EMIT_LOC_STRINGS": "NO",
        "GENERATE_INFOPLIST_FILE": "NO",
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        # The canvas shader only. The engine's kernels never go through Xcode's
        # metal compiler -- `engine/build.sh ipad` compiles them -- which is the
        # whole reason they are not in the sources phase.
        "MTL_FAST_MATH": "YES",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
    }
    app_cfg = {
        **common,
        "PRODUCT_NAME": PRODUCT_NAME,
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "INFOPLIST_FILE": f"{APP}/Info.plist",
        "CODE_SIGN_ENTITLEMENTS": f"{APP}/{APP}.entitlements",
        "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/Frameworks"',
        "ENABLE_PREVIEWS": "YES",
    }

    def cfg(tag: str, name: str, settings: dict, extra: dict) -> str:
        cid = uid(f"cfg:{tag}:{name}")
        merged = {**settings, **extra}
        body = "\n".join(f"\t\t\t\t{k} = {v};" for k, v in sorted(merged.items()))
        p.add(cid, f"{{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{body}\n"
                   f"\t\t\t}};\n\t\t\tname = {name};\n\t\t}}", name)
        return cid

    # The engine's C++ stays -O2 in Debug, exactly as on the Mac: at -O0 its
    # host-side work ran 12x slower and Debug was judged by that.
    debug = {"SWIFT_OPTIMIZATION_LEVEL": '"-Onone"', "DEBUG_INFORMATION_FORMAT": "dwarf",
             "ENABLE_TESTABILITY": "YES", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
             "GCC_OPTIMIZATION_LEVEL": "2"}
    release = {"SWIFT_OPTIMIZATION_LEVEL": '"-O"', "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
               "SWIFT_COMPILATION_MODE": "wholemodule"}

    def cfg_list(tag: str, settings: dict) -> str:
        d = cfg(tag, "Debug", settings, debug)
        r = cfg(tag, "Release", settings, release)
        lid = uid(f"cfglist:{tag}")
        p.add(lid, f"{{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n"
                   f"\t\t\t\t{d} /* Debug */,\n\t\t\t\t{r} /* Release */\n\t\t\t);\n"
                   f"\t\t\tdefaultConfigurationIsVisible = 0;\n"
                   f"\t\t\tdefaultConfigurationName = Release;\n\t\t}}", tag)
        return lid

    # The pre-build check. A script file rather than an escaped one-liner so it
    # can be run on its own, and because a failure here should name the command
    # that fixes it rather than a build setting.
    check_script = uid("phase:app:check-resources")
    p.add(check_script,
          "{\n\t\t\tisa = PBXShellScriptBuildPhase;\n\t\t\tbuildActionMask = 2147483647;"
          "\n\t\t\tfiles = (\n\t\t\t);\n\t\t\tinputPaths = (\n\t\t\t);"
          "\n\t\t\tname = \"Check Pad resources\";\n\t\t\toutputPaths = (\n\t\t\t);"
          "\n\t\t\trunOnlyForDeploymentPostprocessing = 0;"
          "\n\t\t\tshellPath = /bin/sh;"
          "\n\t\t\tshellScript = \"\\\"$SRCROOT/Tools/check-pad-resources.sh\\\"\\n\";"
          "\n\t\t}", "Check Pad resources")

    app_target = uid("target:app")
    project = uid("project")
    p.add(app_target, f"{{\n\t\t\tisa = PBXNativeTarget;\n"
                      f"\t\t\tbuildConfigurationList = {cfg_list('app', app_cfg)};\n"
                      f"\t\t\tbuildPhases = (\n\t\t\t\t{check_script},\n\t\t\t\t{app_sources},\n"
                      f"\t\t\t\t{app_frameworks},\n\t\t\t\t{asset_catalogue},\n"
                      f"\t\t\t\t{app_resources}\n\t\t\t);\n"
                      f"\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n"
                      f"\t\t\tname = {APP};\n\t\t\tproductName = {APP};\n"
                      f"\t\t\tproductReference = {app_product};\n"
                      f"\t\t\tproductType = \"com.apple.product-type.application\";\n\t\t}}", APP)

    proj_cfg = cfg_list("project", {"SWIFT_VERSION": "6.0",
                                    "IPHONEOS_DEPLOYMENT_TARGET": IPADOS,
                                    "SDKROOT": "iphoneos",
                                    "ALWAYS_SEARCH_USER_PATHS": "NO",
                                    "CLANG_ENABLE_OBJC_ARC": "YES",
                                    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
                                    "GCC_NO_COMMON_BLOCKS": "YES",
                                    "ENABLE_USER_SCRIPT_SANDBOXING": "NO"})
    p.add(project, f"{{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {{\n"
                   f"\t\t\t\tBuildIndependentTargetsInParallel = 1;\n"
                   f"\t\t\t\tLastSwiftUpdateCheck = 1600;\n"
                   f"\t\t\t\tLastUpgradeCheck = 1600;\n\t\t\t}};\n"
                   f"\t\t\tbuildConfigurationList = {proj_cfg};\n"
                   f"\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n"
                   f"\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n"
                   f"\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase\n\t\t\t);\n"
                   f"\t\t\tmainGroup = {main_group};\n\t\t\tproductRefGroup = {products};\n"
                   f"\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n"
                   f"\t\t\ttargets = (\n\t\t\t\t{app_target}\n\t\t\t);\n\t\t}}", "Project object")

    body = "\n".join(p.objects)
    pbx = (f"// !$*UTF8*$!\n{{\n\tarchiveVersion = 1;\n\tclasses = {{\n\t}};\n"
           f"\tobjectVersion = 56;\n\tobjects = {{\n{body}\n\t}};\n"
           f"\trootObject = {project} /* Project object */;\n}}\n")

    scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2660"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES"
      buildArchitectures = "Automatic">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{app_target}"
               BuildableName = "{PRODUCT_NAME}.app"
               BlueprintName = "{APP}"
               ReferencedContainer = "container:{APP}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      shouldAutocreateTestPlan = "YES">
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES"
      queueDebuggingEnableBacktraceRecording = "Yes">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target}"
            BuildableName = "{PRODUCT_NAME}.app"
            BlueprintName = "{APP}"
            ReferencedContainer = "container:{APP}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target}"
            BuildableName = "{PRODUCT_NAME}.app"
            BlueprintName = "{APP}"
            ReferencedContainer = "container:{APP}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
    return pbx, scheme


def main() -> None:
    pbx_path = ROOT / f"{APP}.xcodeproj" / "project.pbxproj"
    scheme_path = ROOT / f"{APP}.xcodeproj" / "xcshareddata" / "xcschemes" / f"{APP}.xcscheme"
    pbx, scheme = build()
    if "--check" in sys.argv:
        stale = []
        for path, text in ((pbx_path, pbx), (scheme_path, scheme)):
            if not path.exists() or path.read_text() != text:
                stale.append(path)
        if stale:
            for path in stale:
                print(f"{path} is stale")
            print("run Tools/gen-ipad-project.py")
            sys.exit(1)
        print(f"{APP}.xcodeproj is current")
        return
    scheme_path.parent.mkdir(parents=True, exist_ok=True)
    pbx_path.parent.mkdir(parents=True, exist_ok=True)
    pbx_path.write_text(pbx)
    scheme_path.write_text(scheme)
    print(f"wrote {pbx_path}")
    print(f"wrote {scheme_path}")


if __name__ == "__main__":
    main()
