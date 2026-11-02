// swift-tools-version: 6.0
//
//  Package.swift -- the iPadOS/iPhone app as a SwiftPM package, so it can be
//  built from Windows + WSL with `xtool dev build` and installed on a real
//  device without a Mac. See PORT-IOS.md.
//
//  This package is *not* how the macOS app is built. The Mac keeps its
//  generated Xcode projects (`modern_UI/Spektrafilm/Spektrafilm.xcodeproj` for
//  macOS, `SpektraPad.xcodeproj` for the simulator/device from Xcode); this
//  file exists only because xtool drives SwiftPM. Two consequences that the
//  reader will otherwise trip over:
//
//  * The app target lists whole directories in `sources:` and takes files
//    *out* with `exclude:`. A new shared Swift file is therefore picked up
//    with no edit here, but a new file that must not ship on iOS (a Mac-only
//    window, the agent's CLI) has to be added to `exclude:` or the build
//    starts compiling AppKit code.
//
//  * The C ABI arrives as a Swift module (`import SpekEngine`) instead of the
//    bridging header the Xcode targets use. `Service/EngineClient.swift`
//    guards that import with `#if canImport(SpekEngine)`, so the same file
//    compiles both ways.
//
//  What this package *cannot* do is compile Metal: `metal` and `metallib` are
//  Mach-O tools that ship inside Xcode and do not run under WSL, so the two
//  `.metallib` files are inputs to this build, not products of it. See
//  "Metal" in PORT-IOS.md.

import PackageDescription

let package = Package(
    name: "SpektraPad",
    platforms: [.iOS("17.0")],
    products: [
        // A library, not an executable: xtool links the app bundle itself and
        // reads the entry point from `@main` (the same shape the reference
        // xtool project uses for its keyboard app).
        .library(name: "SpekPad", targets: ["SpekPad"])
    ],
    targets: [
        // The C++20 render engine. `build.sh` compiles the same three folders
        // for the Mac; the folders that are Mac-only (`io` = LibRaw decode,
        // `desktop` = the native shell) and the two files that belong to other
        // platforms are excluded rather than conditionally compiled.
        .target(
            name: "SpekEngine",
            path: "engine",
            exclude: [
                "src/io",
                "src/desktop",
                "src/shaders",
                "src/gpu/vulkan_gpu.cpp",
                "src/pipeline/windows_unported.cpp",
                "tests",
                "tools",
                "host",
                "cmake",
                "resources",
                "resources_product",
                "third_party/stb",
                "third_party/volk"
            ],
            sources: ["src/core", "src/gpu", "src/pipeline"],
            publicHeadersPath: "include",
            cxxSettings: [
                // `metal-cpp` is the reason for the third path: the engine says
                // `#include <Metal/Metal.hpp>`, and without `-I` to
                // `third_party/metal-cpp` clang resolves `<Metal/...>` to the
                // SDK framework, which has no such header.
                .headerSearchPath("include"),
                .headerSearchPath("src"),
                .headerSearchPath("src/core"),
                .headerSearchPath("third_party/metal-cpp"),
                // The engine itself is C++20 (`build.sh`); metal-cpp needs
                // only C++17, so one flag covers both.
                .unsafeFlags(["-std=c++20"])
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("Foundation"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Accelerate")
            ]
        ),
        // The app: every shared Swift file the Mac target also compiles, plus
        // the iPad shell in `SpektraPad/`.
        .target(
            name: "SpekPad",
            dependencies: ["SpekEngine"],
            path: "modern_UI/Spektrafilm",
            exclude: [
                "Spektrafilm/Windows",
                "Spektrafilm/Agent",
                "Spektrafilm/Updates",
                "Spektrafilm/Resources",
                "Spektrafilm/SpektraLab.icon",
                "Spektrafilm/SpektrafilmApp.swift",
                "Spektrafilm/Canvas/MetalCanvasView.swift",
                // SwiftPM/xtool compiles `.metal` files found in a target with
                // Apple's `metal` driver -- a Mach-O binary, so under WSL the
                // build dies with "unable to spawn process 'metal'". The
                // canvas library is therefore an input (`default.metallib`,
                // produced by Tools/build-metallib.sh on a Mac and listed in
                // xtool.yml) instead of a product of this target.
                "Spektrafilm/Canvas/Shaders.metal",
                "Spektrafilm/Export/ExportPage.swift",
                "Spektrafilm/Info.plist",
                "Spektrafilm/Spektrafilm.entitlements",
                "Spektrafilm/Service/Spektrafilm-Bridging-Header.h",
                // SwiftPM treats an asset catalogue as a resource and asks
                // Xcode's `actool` to compile it -- which is a Mach-O binary
                // under WSL. Nothing in the app reads a colour or an image by
                // name (`Theme.accent` is Swift), so the catalogue stays out
                // of the iPad target rather than needing a Mac to compile it.
                "Spektrafilm/Assets.xcassets",
                "SpektraPad/Info.plist",
                "SpektraPad/Info-xtool.plist",
                "SpektraPad/SpektraPad.entitlements"
            ],
            sources: ["Spektrafilm", "SpektraPad"],
            swiftSettings: [
                // The generated Xcode project sets `SWIFT_VERSION = 6.0` and
                // `SWIFT_STRICT_CONCURRENCY = complete`; `.v6` is the same
                // language mode, so a file that compiles here compiles there.
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Accelerate")
            ]
        )
    ]
)
