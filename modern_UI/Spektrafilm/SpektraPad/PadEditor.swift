//  PadEditor.swift — the detail column: the canvas, its overlays, and the
//  inspector.
//
//  The Mac's `EditorWindow` is a fixed three-column layout with two resizable
//  rails and a filmstrip under the canvas. None of that survives here, and the
//  reason is not taste: a split view that the system collapses is what makes
//  one build work on a 6.1" iPhone, a 13" iPad and whatever shape the foldable
//  opens to. So the rails become `.inspector` (a trailing column on a wide
//  iPad, a sheet on an iPhone), the filmstrip becomes the sidebar
//  (`PadLibrary`), and the canvas keeps the whole remaining area.
//
//  Everything inside the canvas is the shared code unmodified: `PadCanvas`
//  drives `Renderer`, and `CropOverlay`/`MaskOverlay`/`CompareOverlay`/
//  `PairOverlay` are the same views the Mac draws, reading the same `Session`.
//  The one thing this file decides alone is *where* chrome sits, which is the
//  one thing a platform is entitled to decide.

import SwiftUI
import UniformTypeIdentifiers

struct PadEditor: View {
    @Bindable var session: Session
    @State private var inspector = false
    @State private var dropTargeted = false

    var body: some View {
        ZStack {
            Theme.ground.ignoresSafeArea()
            if session.selection == nil {
                PadEmptyCanvas { session.importRequested = true }
            } else {
                canvas
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .inspector(isPresented: $inspector) {
            RightPanel(session: session)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
        }
        .sheet(isPresented: $session.showExport) {
            PadExport(session: session)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            accept(providers)
        }
    }

    @MainActor private var title: String {
        session.selection?.lastPathComponent ?? "SpektraPad"
    }

    // MARK: canvas

    @MainActor private var canvas: some View {
        ZStack {
            PadCanvas(host: session)

            // The overlays report hit tests only where they draw something, so
            // the canvas underneath still receives every gesture that is not
            // on a handle.
            if session.tool == .crop {
                CropOverlay(session: session)
            } else if FeatureFlags.masks, session.selectedMask != nil {
                MaskOverlay(session: session)
            }
            CompareOverlay(session: session)
            if session.pair != nil {
                PairOverlay(session: session)
            }
        }
        .overlay(alignment: .bottomLeading) {
            PadStatusOverlay(session: session)
                .padding(.leading, 12)
                .padding(.bottom, 10)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .clipped()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PadToolStrip(session: session, inspectorPresented: $inspector)
        }
    }

    // MARK: toolbar

    @ToolbarContentBuilder
    @MainActor private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                session.solveNow()
            } label: {
                Label(L(.actionSolve), systemImage: "wand.and.stars")
            }
            .disabled(!session.canSolve)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                session.showExport = true
            } label: {
                Label(L(.helpExport), systemImage: "square.and.arrow.up")
            }
            .disabled(session.selection == nil)
        }
    }

    // MARK: drop

    /// Dragging a picture from Files onto the canvas is the one import gesture
    /// that works without a picker. `Session.dropped(files:)` is the same entry
    /// point the Mac's `.onDrop` uses, so the "is this a folder, is it already
    /// open, which frame becomes the selection" rules are not duplicated here.
    @MainActor private func accept(_ providers: [NSItemProvider]) -> Bool {
        let collector = URLColector()
        let group = DispatchGroup()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { collector.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = collector.urls
            guard !urls.isEmpty else { return }
            Task { @MainActor in
                SecurityScopedURLs.keep(urls)
                session.dropped(files: urls)
            }
        }
        return true
    }
}

/// The drag callbacks arrive on whatever queue Files uses and more than one can
/// be in flight, so the URLs are gathered behind a lock rather than appended to
/// a captured array — which Swift 6 rejects, and which would be a data race if
/// it did not.
private final class URLColector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func append(_ url: URL) {
        lock.lock(); storage.append(url); lock.unlock()
    }

    var urls: [URL] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
