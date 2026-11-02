# PORT-IOS.md — the iPadOS / iOS port

`SpektraPad` is the Apple-native iOS build of SpektraLab. It is not a separate
application: the whole model, engine client, canvas renderer, parameter
sections, overlays, import decoder and export writer are the **same files** the
macOS target compiles. This document records what is shared, what was added,
how to build it, and what is honestly still missing.

Read `PORT_PLAN.md` for the platform-porting context that came before this, and
`ARCHITECTURE.md` for the pipeline itself.

## What this is

- **Targets**: iPhone and iPad (`TARGETED_DEVICE_FAMILY = 1,2`), iOS 17.
- **Product name**: `SpektraPad`. The SpektraLab name and icon are the
  upstream author's trademark (`README.md`); a published fork must carry its
  own, so the port does.
- **Bundle id**: `com.hanze.filmify.pad`.
- **Interface**: one `NavigationSplitView`. Wide: frame list beside the canvas,
  parameters in `.inspector`. Narrow (Split View, Slide Over, iPhone, the
  foldable closed): the same declaration collapses into a push stack. There is
  no second layout and no size-class branch in the app code — the split view
  is the branch, and it is the system's.

## What is shared, unmodified

| Area | Files |
|---|---|
| Model | `Model/Session.swift` and the rest of `Model/` |
| Engine | `Service/EngineClient.swift`, `Service/Methods.swift`, `Service/RenderScheduler.swift`, all of `engine/src/**` |
| Canvas | `Canvas/Renderer.swift`, `TextureStore`, `ColourManagement`, `CineonLUT`, `ViewportState`, `ViewportState`'s `CanvasHost`, the four overlays, `Shaders.metal` |
| Panels | `Panels/LeftPanel.swift`, `Panels/RightPanel.swift`, every `Panels/Sections/*`, `Filmstrip`, `CropMaskedThumbnail` |
| Controls | all of `Controls/` |
| Import / Export | `Import/ImageDecoder`, `PairComposer`, `ThumbnailCache`, `FramePipeline`; `Export/ExportRecipe`, `Exporter`, `SoftProof` |
| Diagnostics | `Diagnostics/*` (the log bundle is portable; only "Reveal in Finder" is Mac-only) |
| Theme / strings | `Theme/Theme.swift`, `Localization/*` |

Two kinds of edit were needed to make that true, and both preserve macOS
behaviour exactly:

1. **Platform vocabulary** in `Theme/Theme.swift` (`PlatformFont`,
   `PlatformInput`, `PlatformCursor`, `srgbComponents(of:)`) plus three `View`
   helpers — `help(_:)` (a no-op on iOS: there is no tooltip), `menuStyleButton()`
   and `cursorOnHover(_:)`. Call sites read the same on both platforms.
2. **`#if canImport(AppKit)`** around the genuinely Mac-only blocks: the two
   `NSMenu` context menus in `Session`, `Library.chooseFilesOrFolder` (on iOS
   `Session.openPanel()` sets `importRequested` instead), the drag-to-delete
   point menu in `CurveEditor`, and `Diagnostics.revealLogsInFinder()`.
3. **One value moved out of a Mac-only file.** `Theme.Metric.trafficLightClearance`
   read `TrafficLightAlignment.rowWidth`, which is declared in
   `Windows/TrafficLights.swift` — a file the Pad target does not compile, so the
   whole target would have failed on a constant. The number now lives in
   `Theme.Metric.trafficLightRowWidth` (with the 20 pt spacing / 14 pt button it is
   derived from spelled out), and the Mac's `TrafficLightAlignment.rowWidth`
   returns it so the two cannot drift.

`Canvas/MetalCanvasView.swift` keeps `CanvasNSView`; `CanvasTool`,
`StraightenLine` and the `CanvasHost` protocol moved into
`Canvas/ViewportState.swift` so both canvases can implement it.

## What was added (all under `modern_UI/Spektrafilm/SpektraPad/`)

| File | What it is |
|---|---|
| `SpektraPadApp.swift` | `@main`, the one `Session`, `PadRoot`'s split view and boot overlay |
| `PadRoot` (same file) | `NavigationSplitView`, boot gate |
| `PadLibrary.swift` | native frame list; `.fileImporter`; `SecurityScopedURLs` |
| `PadEditor.swift` | canvas + overlays + toolbar + `.inspector` + drop target + export sheet |
| `PadCanvas.swift` | UIKit `MTKView` canvas: pan/pinch/tap/double-tap/two-finger/rotation, hardware keys, crop drag semantics |
| `PadChrome.swift` | `WindowDragHandle` no-op, boot overlay, status capsule, bottom tool strip, empty state |
| `PadExport.swift` | export sheet (format, colour space, quality, long edge) + share sheet |
| `Info.plist` | bundle identity, launch screen, document sharing, orientations, document types |
| `SpektraPad.entitlements` | empty, deliberately |

Generated project: `Tools/gen-ipad-project.py` writes
`SpektraPad.xcodeproj` (pbxproj + shared scheme) from the filesystem, exactly
as `Tools/gen-project.py` does for the Mac. It filters the shared tree:
`Windows/`, `Agent/`, `Updates/`, `Resources/`, `SpektrafilmApp.swift`,
`Canvas/MetalCanvasView.swift`, `Export/ExportPage.swift` and
`SpektraLab.icon` are excluded. The icon document is excluded for two reasons:
`folder.iconcomposer.icon` is a macOS-only asset type, and the icon is the
upstream author's trademark. `Assets.xcassets` — which holds only
`AccentColor` — is compiled as an asset catalogue, and **the Pad has no app
icon yet**; a store submission needs one of its own.

## Building

```sh
# 1. Compile the iOS Metal library and stage the resources.
engine/build.sh ipad

# 2. (Re)generate the project after adding or removing a .swift or .cpp file.
cd modern_UI/Spektrafilm
python3 Tools/gen-ipad-project.py          # add --check in CI

# 3. Build.
xcodebuild -project SpektraPad.xcodeproj -scheme SpektraPad -destination 'generic/platform=iOS' build
```

`engine/build.sh ipad` is a separate verb from `bundle` because the two
libraries are different compilations of the same kernels: the Mac's is
`-mmacos-version-min=15.0`, the Pad's is `arm64-apple-ios17.0`, and both keep
`-fmetal-math-mode=safe -fmetal-math-fp32-functions=precise`. That flag pair is
load-bearing (AGENTS.md trap 1): without it `exp` and the fma path drift past
the float32 bar silently, and `spk_math_probe` will refuse to start the engine.
The Xcode target's `MTL_FAST_MATH = YES` applies only to `Canvas/Shaders.metal`,
which is why the engine kernels are never in the target's compile phase.

Resources land in `modern_UI/Spektrafilm/SpektraPadResources/Resources/` and
are git-ignored; `Tools/check-pad-resources.sh` fails the build if they are
missing or stale-looking. `EngineClient`'s bundle lookup
(`Resources/engine/spektrafilm_constants.bin`) works unchanged because the
folder reference preserves that layout inside the app bundle.

## Building without a Mac (xtool, Windows + WSL)

The same sources also build through SwiftPM and [xtool](https://github.com/xtool-org/xtool),
which cross-compiles, signs and installs from a Windows + WSL host. This is the
route that first compiled the port, so it is the one to trust when the two
diverge.

```sh
# On Windows, one-time: install WSL tooling (xtool, Swift, the Darwin SDK).
wsl -e bash -lc 'xtool setup'

# Then, for each build: rsync the checkout and compile inside WSL.
wsl -e bash -lc 'Tools/build-ipad.sh -c debug'          # add --sign --ipa to package
```

What the two entry points are:

| File | Role |
|---|---|
| `Package.swift` | `SpekEngine` (C++20, `engine/src/{core,gpu,pipeline}`) and `SpekPad` (shared + Pad Swift, `swiftLanguageMode(.v6)`). Directories, not file lists: a new `.swift` is picked up without regenerating anything. |
| `xtool.yml` | Bundle id, product, `Info-xtool.plist`, entitlements, and the two resources that must sit at the bundle root. |
| `Tools/build-ipad.sh` | rsync into `$HOME/Projects/SpektraPad` (excluding `.git`, `build`, `.build`, `DerivedData`, `SpektraPadResources`) then `xtool dev build`. |
| `SpektraPad/Info-xtool.plist` | Literal plist for xtool: the Xcode one uses `$(…)` build settings that nothing expands here. |

**Metal is the one step this host cannot do.** The Darwin Swift SDK ships a
whole `Xcode.app`, but its `metal` and `actool` are Mach-O and fail with
`Exec format error` under Linux — so the two libraries are inputs, not products,
on this path. The repository builds them itself, on a macOS runner:

```sh
# Once (and again whenever a shader changes): .github/workflows/ipad-metallib.yml
# runs on macos-15 for a push to `ipad-port` and publishes two flat release
# assets on the `ipad-metallib` tag.
wsl -e bash -lc 'Tools/fetch-metallibs.sh'   # → SpektraPadResources/, magic-checked
```

Or, on a Mac, the same two files by hand:

```sh
engine/build.sh ipad                       # → SpektraPadResources/Resources/engine/spektrafilm.metallib
Tools/build-metallib.sh                    # → SpektraPadResources/default.metallib
```

`Tools/build-ipad.sh` refuses to start without both, and names those routes. The
engine's library keeps the safe/fast math split described above; the canvas one
is compiled fast because the Mac target sets `MTL_FAST_MATH = YES` for it.

Both libraries carry a platform stamp (`PlatformMajor: 17`), which is why the
Mac's own `spektrafilm.metallib` cannot be reused: it loads on macOS and fails
at `newLibraryWithURL` on iOS.

## Deliberate gaps

These are Mac surfaces with no iOS equivalent yet. None of them changes the
pixels the port can produce.

| Missing | Why / what it would take |
|---|---|
| `Windows/SettingsWindow` (Rendering, Memory, Diagnostics, and the interface-scale control) | The settings model is on `Session` and `UserDefaults`; a `Form`-based Pad settings sheet would be a straight rebuild. Not written yet. |
| `Export/ExportPage` (recipe list, naming-rule chips, open-with, batch frame picker) | `PadExport` covers format/space/quality/size. Recipes are `Codable` and `ExportRecipeStore` is portable, so a recipe editor is a view job, not a model job. |
| Agent CLI / MCP server | `ProcessInfo.arguments`, `FileHandle.standardError` and subprocesses have no iOS meaning. Excluded from the target. |
| Update check (`Updates/UpdateCheck.swift`) | Sparkle-style update checks are not an App Store mechanism. |
| The Mac's window chrome (`TopBar`, `TrafficLights`, `CollapseTab`, `HoverEdgeTab`, panel resize handles, `WindowDragHandle` drag) | Replaced by the navigation bar, the tool strip and `.inspector`. The shared rails still call `WindowDragHandle`, which the Pad target defines as `Color.clear`. |
| Menu commands (⌘O, ⌘E, ⇧⌘C, ⇧⌘V, ⌘Z) | iOS has no `Commands` scene. The canvas answers hardware keys directly (space, arrows, Z, return, escape); copy/paste/undo would need toolbar buttons or `.keyboardShortcut` on them. |
| Filmstrip drag-reorder | `Filmstrip` itself is portable, but the Pad's frame list is `PadLibrary`; reordering there is not wired. |

## Known risks to check on device

1. **Rotation gesture sign.** `UIRotationGestureRecognizer.rotation` is positive
   clockwise in UIKit's flipped space; the Pad applies
   `origin.straightened(to: start.angle + degrees)`. The Mac's ⌘-drag is the
   reference. Verify against a straight edge; if it turns the wrong way, the
   fix is the sign in `PadCanvasView.handleRotate`.
2. **`.inspector` on iPhone.** SwiftUI presents it as a sheet in compact width;
   confirm the toolbar's inspector button is visible in the collapsed stack.
3. **Security-scoped URLs.** `SecurityScopedURLs` holds every imported URL for
   the life of the process rather than stopping the scope, because the engine
   decodes lazily and a timer that guesses wrong fails mid-export. If a frame
   ever opens correctly once and fails later, this is the first place to look.
4. **Memory.** A full-resolution render holds ~458 MB per `EngineClient`
   (the handle box's comment records it). iOS jetsam will be less forgiving
   than macOS; `Diagnostics/MemoryArena` and `TextureStore` are the same code,
   so the pressure behaviour should be the same, but check a 45 MP frame on the
   smallest supported device.
5. **Nothing here has been compiled.** This checkout is on Windows, with no
   Xcode and no iOS SDK. The shared-source edits were checked by reading and by
   symbol audits, not by a compiler. The first Mac build will find type errors.

## Verification status

- `Tools/gen-project.py --check` → current (macOS project regenerated for the
  two new `Tools/` files; its diff is those two file references).
- `Tools/gen-ipad-project.py --check` → current; the generated project
  contains 90 Swift references, 23 C++ references, no `MetalCanvasView.swift`,
  no `ExportPage.swift`, no `Windows/`, no `Agent/`, and
  `TARGETED_DEVICE_FAMILY = 1,2`.
- `engine/build.sh` passes `bash -n` (Git Bash). The `ipad` verb itself has not
  been run — it needs `xcrun`. `Tools/check-pad-resources.sh` passes `bash -n`
  as well.
- Every `session.*` / `renderer.*` member the Pad shell calls was checked
  against the shared sources (43 names, all present), and every `host.*` call in
  `PadCanvas.swift` against the `CanvasHost` protocol (21 names, no extras).
- Cross-tree audit: the 52 types declared only in files the Pad target excludes
  were checked for use by the 84 shared files it keeps — every remaining hit is a
  comment or `WindowDragHandle`, which `PadChrome.swift` defines as a no-op. The
  same check over top-level functions and globals found zero hits.
- **Compiled for iOS** through the xtool path: `xtool dev build -c debug`
  reports `Build complete!` after compiling the 25 engine `.cpp` files (C++20 +
  metal-cpp) and all 90 Swift files for `arm64-apple-ios17.0`. The product is a
  16 MB `Mach-O 64-bit arm64` executable; the bundle carries `Info.plist`
  (`com.hanze.filmify.pad`, `MinimumOSVersion 17.0`, `UIDeviceFamily [1,2]`),
  `Resources/engine/spektrafilm_constants.bin` and — until a Mac provides the
  real ones — placeholder metallibs.
- **Signed and packaged**: `xtool dev build -c release --sign --ipa` produced a
  16 MB `xtool/SpekPad.ipa` with a development profile (`XTL profile
  A94WRP457B`, team `MGW6249V63`, `get-task-allow`, two registered device
  UDIDs, expires 2026-11-09).
- Not verified: launching. Both metallibs are placeholders, so `Renderer.init`
  returns nil and the engine cannot load a library; the first on-device run has
  to follow the Mac/CI Metal step. Installing also needs the iPad reachable over
  usbmuxd (`xtool devices` is empty on this host until the USB relay runs).

## Licence and attribution

The app and engine are GPL-3.0-or-later; profiles and print LUTs are
CC BY-SA 4.0; vendored metal-cpp is Apache-2.0. The Pad bundle carries the same
licence texts (`SpektraPadResources/Resources/Licenses/`) and
`Tools/check-pad-resources.sh` fails the build if they are missing. A
distributed build must also use a name and icon that are not the upstream
author's.
