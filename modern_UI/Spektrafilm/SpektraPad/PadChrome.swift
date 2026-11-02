//  PadChrome.swift — the platform vocabulary the shared views need, and the
//  small pieces of chrome the iPad shell draws itself.
//
//  The app is one app: `Spektrafilm/` holds the model, the engine client, the
//  canvas renderer, the parameter sections and the export writer, and both
//  targets compile it. This file supplies what the shared tree asks the
//  platform for — on macOS those answers live in the window layer
//  (`Windows/EditorWindow.swift`, `Windows/TrafficLights.swift`), which is
//  exactly the layer iPadOS does not have.

import SwiftUI

/// The shared rails and the Mac's tool bar call this to make a header row drag
/// the window. iPadOS has no titlebar and no free-floating windows: a sheet is
/// dragged by its grabber, and the one window there is is moved by the system.
/// The call sites stay as they are and the modifier draws nothing.
struct WindowDragHandle: View {
    var body: some View { Color.clear }
}

// MARK: - boot

/// What the app shows until the engine answers.
///
/// `Session.init` starts `warmUp()` on its own — there is no separate start
/// call to make — so this overlay is not a gate the shell controls, it is the
/// visible part of a state machine the model already owns (`Session.BootPhase`).
/// On the Mac the same information is a separate boot window with a progress
/// bar; on iPadOS a full-screen `ProgressView` over the ground is the native
/// shape of it, and the artwork people are waiting for is what they see next.
struct PadBootOverlay: View {
    @Bindable var session: Session

    var body: some View {
        switch session.bootPhase {
        case .ready:
            EmptyView()
        case .starting, .warming:
            VStack(spacing: 18) {
                ProgressView().controlSize(.large).tint(Theme.accent)
                Text(session.bootPhase.label)
                    .font(.callout)
                    .foregroundStyle(Theme.Ink.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.ground.ignoresSafeArea())
            .transition(.opacity)
        case .failed(let reason):
            ContentUnavailableView {
                Label(L("The render engine could not start", zh: "渲染引擎无法启动"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(reason).font(.footnote)
            } actions: {
                Button(L("Try Again", zh: "重试")) { session.restartService() }
                    .buttonStyle(.borderedProminent)
            }
            .background(Theme.ground.ignoresSafeArea())
        }
    }
}

// MARK: - status

/// The canvas's own status: what the engine is doing, how big the print is,
/// and whether the service went away. The Mac puts this on the tool bar; on
/// iPadOS the bar belongs to the navigation stack, so it sits over the
/// photograph's bottom edge where it is legible and out of the way.
struct PadStatusOverlay: View {
    @Bindable var session: Session

    @MainActor private var text: String {
        guard session.working else { return session.status }
        return String(format: "%@ · %.1f s", session.status, session.workSeconds)
    }

    var body: some View {
        HStack(spacing: 10) {
            if session.working {
                ProgressView().controlSize(.mini).tint(Theme.accent)
            }
            Text(text)
                .font(.caption2)
                .foregroundStyle(Theme.Ink.tertiary)
                .lineLimit(1)
            if !session.serviceReady, session.selection != nil {
                Button(L(.actionRestart)) { session.restartService() }
                    .font(.caption2.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.rule, lineWidth: 0.5))
    }
}

// MARK: - tools

/// The bottom tool strip: the canvas tools, the two canvas-wide modes, and the
/// frame stepper.
///
/// This is the iPad's answer to the Mac's top bar. The Mac can afford a
/// 38 pt bar with eleven controls on it because a pointer hits 28 pt targets;
/// a finger cannot, so the same choices are split: the *tools* stay one tap
/// away at the bottom (where a thumb is), and everything that is a property of
/// the picture — import, export, undo, the inspector — moves to the navigation
/// bar at the top, which is where iPadOS puts actions.
struct PadToolStrip: View {
    @Bindable var session: Session
    @Binding var inspectorPresented: Bool

    var body: some View {
        HStack(spacing: 0) {
            Picker(L(.helpSelect), selection: $session.tool) {
                Image(systemName: "cursorarrow").tag(CanvasTool.select)
                Image(systemName: "hand.draw").tag(CanvasTool.hand)
                Image(systemName: "crop").tag(CanvasTool.crop)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)

            Spacer(minLength: 12)

            Button {
                session.toggledOriginal(!session.showingOriginal)
            } label: {
                Label(L(.actionOriginal), systemImage: session.showingOriginal ? "eye.fill" : "eye")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 18))
                    .frame(width: 44, height: 44)
            }
            .disabled(session.selection == nil || session.filmEdgeShowsFilm)
            .accessibilityLabel(L(.actionOriginal))

            Button {
                session.comparing.toggle()
            } label: {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 17))
                    .frame(width: 44, height: 44)
            }
            .disabled(!session.canCompare)
            .accessibilityLabel(L(.helpBeforeAfter))

            Button {
                session.zoomStep(-1)
            } label: {
                Image(systemName: "minus.magnifyingglass").font(.system(size: 17)).frame(width: 44, height: 44)
            }
            .disabled(session.zoomLocked)

            Button {
                session.zoomStep(1)
            } label: {
                Image(systemName: "plus.magnifyingglass").font(.system(size: 17)).frame(width: 44, height: 44)
            }
            .disabled(session.zoomLocked)

            Spacer(minLength: 12)

            Button {
                withAnimation(.snappy) { inspectorPresented.toggle() }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(L(.railParameters))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.rule).frame(height: 0.5) }
    }
}

// MARK: - empty states

/// Nothing open yet. A folder dropped on the window, or the Files picker, is
/// the only way in — there is no import window on this platform, and no
/// Browse grid: the frame list is the sidebar.
struct PadEmptyCanvas: View {
    let importAction: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(L("No photograph open", zh: "尚未打开照片"), systemImage: "photo.on.rectangle.angled")
        } description: {
            Text(L("Open a RAW file, a TIFF or a folder of them to start printing.",
                   zh: "打开 RAW、TIFF 或包含它们的文件夹，开始冲洗。"))
        } actions: {
            Button(L("Open…", zh: "打开…"), action: importAction)
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - layout

extension View {
    /// The iPad's ground, behind everything, extending under the bars. The
    /// shared views paint their own cards; this is the colour the gaps between
    /// them show, and the colour the canvas is surrounded with
    /// (`CanvasGround.value`).
    func padGround() -> some View {
        background(Theme.ground.ignoresSafeArea())
    }
}
