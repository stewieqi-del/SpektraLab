//  SpektraPadApp.swift — the entry point.
//
//  One scene, one `Session`, one window: `NavigationSplitView` is the whole
//  adaptive story. On a wide iPad it is a sidebar beside the canvas; narrowed —
//  Slide Over, Split View, a 6.1" iPhone, the foldable closed — the same
//  declaration collapses into a push stack and the frame list becomes the first
//  screen. That is why there is no second layout and no size-class branching
//  here: the split view *is* the branch, and it is the system's.
//
//  `Session` is created once, at launch, because constructing it starts the
//  engine (`Session.init` ends with `bootTask = warmUp()`), and a scene that
//  made a second one would run a second engine beside the first. The Mac hides
//  that in `@MainActor static let session`; here the scene owns it, which is the
//  same lifetime with a place to say why.
//
//  Not ported, deliberately: the `Settings` window (`Windows/SettingsWindow
//  .swift` is a macOS window), the About panel, the Agent/CLI/MCP layer, and
//  the update check. They are recorded as gaps in PORT-IOS.md.

import SwiftUI

@main
struct SpektraPadApp: App {
    @State private var session = Session()

    var body: some Scene {
        WindowGroup {
            PadRoot(session: session)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct PadRoot: View {
    @Bindable var session: Session
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            PadLibrary(session: session)
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 340)
        } detail: {
            PadEditor(session: session)
        }
        .navigationSplitViewStyle(.balanced)
        // The engine takes a few hundred milliseconds to load its profiles and
        // bake its LUTs, and on the first launch of a fresh install it also
        // reads the film catalogue. Showing a blank canvas during that would
        // read as "nothing opened", so the boot state covers the whole scene
        // rather than only the detail column — including on the iPhone, where
        // the frame list is what is actually on screen.
        .overlay {
            if !session.booted {
                PadBootOverlay(session: session)
            }
        }
    }
}
