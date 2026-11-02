//  PadCanvas.swift — the photograph, under a finger.
//
//  The Mac's canvas is `Canvas/MetalCanvasView.swift`: an `MTKView` subclass
//  that reads a mouse and a scroll wheel. That file is excluded from this
//  target (it is `NSViewRepresentable` and speaks `NSEvent`). This is the same
//  drawing surface and the same interaction *model* — the same viewport, the
//  same crop handles, the same mask grips, the same pair placement — read
//  through gestures instead.
//
//  What deliberately did **not** change is where state lives: every gesture
//  below mutates `Renderer.viewport` or calls a `CanvasHost` method, exactly as
//  the mouse handlers do, so the renderer, the overlays and the export path
//  cannot tell which platform drove them. What did change is the vocabulary:
//
//    - a drag pans; a pinch zooms about the pinch's centre;
//    - a double tap toggles 100 % about the tapped point (the Mac's
//      double-click, and the only zoom gesture a mouse has);
//    - a two-finger tap toggles the original (the Mac holds the space bar,
//      which a finger cannot do); a hardware keyboard's space bar does the
//      same thing here, and releasing it only undoes its own press;
//    - in the crop tool a drag on a grip resizes, a drag inside the frame moves
//      it, and a drag outside turns the photograph — the Mac's three crop
//      drags, with the ⌥-draw-a-new-rectangle gesture replaced by a
//      `UIRotationGestureRecognizer`, which is how every iPad photo app
//      straightens a horizon.
//
//  Two gestures are intentionally absent. There is no hover: a pointer that
//  rests over a grip is an iPad-with-trackpad case, and the grips draw at
//  10 pt already. And there is no right-click: the context menus the Mac puts
//  on the canvas live on the frame list and the toolbar here, which is where
//  iPadOS puts them.

import MetalKit
import SwiftUI
import UIKit

/// The SwiftUI face of the canvas. Owns nothing: the `Session` is the host and
/// the renderer it carries is the same object the panels talk to.
struct PadCanvas: UIViewRepresentable {
    let host: Session

    func makeUIView(context: Context) -> PadCanvasView {
        PadCanvasView.configured(host: host)
    }

    func updateUIView(_ uiView: PadCanvasView, context: Context) {
        uiView.host = host
        // A frame that arrived, a crop that was committed or a window that
        // changed size all land here; the viewport is the thing that has to
        // agree with the new bounds before the next draw.
        uiView.syncViewport()
        uiView.scheduleDraw()
    }
}

// MARK: - the view

@MainActor
final class PadCanvasView: MTKView {
    /// Weak: the session owns the renderer, the renderer's `needsDraw` closure
    /// captures this view weakly, and a frame that closed must not be kept
    /// alive by the canvas that drew it.
    weak var host: CanvasHost?

    private var renderer: Renderer? { host?.renderer }

    /// Set while a draw has been asked for and has not run yet. The Mac's view
    /// coalesces for the same reason: a slider drag sets several pieces of
    /// state per event, and every one of them asks for a draw.
    private var drawScheduled = false

    /// How many times the viewport has been re-fitted to a new size.
    /// `Renderer.drawCount`'s counterpart, and the same kind of evidence: the
    /// canvas itself cannot be seen by a test, but how often it was asked to
    /// change size can be.
    private(set) var resizeCount = 0

    private static let handleGrab: CGFloat = 10

    // One drag at a time, in the shape the drag started in.
    private enum Drag {
        case none
        case pan(from: CGPoint)
        case resize(CropHandle, origin: Geometry, grab: CGSize)
        case move(origin: Geometry, grab: CGSize)
        case rotate(origin: Geometry, centre: CGPoint, from: Double)
        case mask(MaskHandle)
        case placement
    }
    private var drag: Drag = .none
    private var pressPoint: CGPoint?

    // The crop angle a two-finger rotation started from.
    private var rotationStart: (origin: Geometry, angle: Double)?

    // MARK: construction

    static func configured(host: Session) -> PadCanvasView {
        // The session's own device, not `MTLCreateSystemDefaultDevice()`: the
        // engine renders into a texture on that device and the canvas has to
        // draw it, so a second device would mean a copy per frame.
        let view = PadCanvasView(frame: .zero, device: host.renderer.device)
        view.host = host
        view.colorPixelFormat = Renderer.drawableFormat
        view.framebufferOnly = true
        view.autoResizeDrawable = false
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.isMultipleTouchEnabled = true
        view.clearColor = MTLClearColor(red: Double(CanvasGround.value), green: Double(CanvasGround.value),
                                        blue: Double(CanvasGround.value), alpha: 1)
        (view.layer as? CAMetalLayer)?.colorspace = ImageDecoder.workingSpace
        view.layer.backgroundColor = CGColor(srgbRed: 0x5F / 255, green: 0x5F / 255,
                                             blue: 0x5F / 255, alpha: 1)
        view.delegate = view
        // The view asks for one draw; it does not run at 60 Hz. Every state
        // change in the app funnels through this closure, which is why the
        // renderer stays a pure function of its inputs.
        view.renderer?.needsDraw = { [weak view] in view?.scheduleDraw() }
        view.configureGestures()
        return view
    }

    private func configureGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        addGestureRecognizer(twoFingerTap)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.require(toFail: doubleTap)
        tap.require(toFail: twoFingerTap)
        // A press that panned is not a click. The pan only fails once the
        // touch ends without moving, so the tap still lands on a still finger.
        tap.require(toFail: pan)
        addGestureRecognizer(tap)

        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(handleRotate(_:)))
        rotate.delegate = self
        addGestureRecognizer(rotate)
    }

    // MARK: layout

    override func layoutSubviews() {
        super.layoutSubviews()
        sizeDrawable()
        syncViewport()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncViewport()
    }

    override var canBecomeFirstResponder: Bool { true }

    /// Make the drawable **cover** the layer. `autoResizeDrawable` rounds the
    /// drawable down to whole pixels while the layer keeps the fractional
    /// size, and the sliver that leaves is black on the right and bottom — the
    /// Mac's measurement, and the same failure on this platform.
    private func sizeDrawable() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.screen.scale ?? contentScaleFactor
        let want = CGSize(width: ceil(bounds.width * scale), height: ceil(bounds.height * scale))
        if drawableSize != want { drawableSize = want }
    }

    /// The viewport learns the canvas changed size here, and nowhere else.
    func syncViewport() {
        guard let renderer, bounds.width > 0, bounds.height > 0 else { return }
        var vp = renderer.viewport
        vp.backingScale = window?.screen.scale ?? contentScaleFactor
        if vp.viewport != bounds.size {
            resizeCount += 1
            vp.resize(viewport: bounds.size)
        }
        if vp != renderer.viewport {
            renderer.viewport = vp
            // The crop tool's view is locked to the whole turned photograph, so
            // a resize there is a refit rather than `resize`'s keep-the-centre:
            // half the picture would otherwise leave the canvas the moment a
            // split view or a rotation changed its size.
            if renderer.editingCrop { renderer.fitRotatedPhoto() }
            host?.viewportChanged()
        }
        scheduleDraw()
    }

    /// One draw, on the next runloop turn. `draw()` runs the delegate
    /// immediately, so the draw can never re-enter a SwiftUI layout pass that
    /// is still running; the flag coalesces a burst of state changes.
    func scheduleDraw() {
        setNeedsDisplay()
        guard !drawScheduled else { return }
        drawScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.drawScheduled = false
            guard self.window != nil, self.bounds.width > 0, self.bounds.height > 0 else { return }
            self.draw()
        }
    }

    // MTKViewDelegate lives in an extension at the end of the file: its
    // requirements are nonisolated (`@objc`) while this view is main-actor
    // isolated, so the two callbacks have to hop explicitly.

    // MARK: points

    private func imagePoint(_ p: CGPoint) -> CGPoint? {
        guard let renderer else { return nil }
        return renderer.viewport.normalised(atView: p)
    }

    /// Unclamped: a drag that leaves the picture is still a drag.
    private func unclampedNormalised(_ p: CGPoint) -> CGPoint {
        guard let renderer else { return .zero }
        let v = renderer.viewport
        let ip = v.imagePoint(atView: p)
        return CGPoint(x: ip.x / max(v.image.width, 1), y: ip.y / max(v.image.height, 1))
    }

    /// View point → edit space, the space the crop tool draws the photograph
    /// turned in. Deliberately unclamped, like the Mac's.
    private func editPoint(_ p: CGPoint) -> CGPoint {
        guard let renderer else { return .zero }
        let v = renderer.viewport
        let ip = v.imagePoint(atView: p)
        return CGPoint(x: ip.x / max(v.image.width, 1), y: ip.y / max(v.image.height, 1))
    }

    private func sourcePoint(_ p: CGPoint) -> CGPoint {
        guard let host, let renderer else { return .zero }
        return host.geometry.sourcePoint(forEdit: editPoint(p), pivot: host.cropPivot,
                                         imageSize: host.sourceImageSize)
    }

    private func clampedSourcePoint(_ p: CGPoint) -> CGPoint {
        let s = sourcePoint(p)
        return CGPoint(x: min(max(s.x, 0), 1), y: min(max(s.y, 0), 1))
    }

    private func viewPoint(ofSource s: CGPoint) -> CGPoint {
        guard let host, let renderer else { return .zero }
        let e = host.geometry.editPoint(forSource: s, pivot: host.cropPivot,
                                        imageSize: host.sourceImageSize)
        let v = renderer.viewport
        return v.viewPoint(atImage: CGPoint(x: e.x * v.image.width, y: e.y * v.image.height))
    }

    private func maskHandle(near p: CGPoint) -> MaskHandle? {
        guard let host, let renderer else { return nil }
        let handles = host.maskHandles
        guard !handles.isEmpty else { return nil }
        let size = host.sourceImageSize
        let v = renderer.viewport
        var best: (MaskHandle, CGFloat)?
        for h in handles {
            let o = host.geometry.outputPoint(forSource: h.position, imageSize: size)
            let q = CGPoint(x: v.offset.x + o.x * v.image.width * v.scale,
                            y: v.offset.y + o.y * v.image.height * v.scale)
            let d = hypot(q.x - p.x, q.y - p.y)
            if d <= Self.handleGrab, best == nil || d < best!.1 { best = (h, d) }
        }
        return best?.0
    }

    /// The pointer's bearing about a view point, in degrees, clockwise from
    /// east — y grows downward, which is the convention `Geometry` uses.
    private static func bearing(from centre: CGPoint, to p: CGPoint) -> Double {
        atan2(p.y - centre.y, p.x - centre.x) * 180 / .pi
    }

    // MARK: tap

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        becomeFirstResponder()
        guard let host, let n = imagePoint(g.location(in: self)) else { return }
        if host.pickerActive { host.picked(normalised: n); return }
        host.clicked(normalised: n)
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        guard let host, let renderer else { return }
        guard host.tool != .crop else { return }   // locked while the frame is up
        let p = g.location(in: self)
        renderer.viewport.toggleHundred(about: p)
        host.viewportChanged()
        scheduleDraw()
    }

    /// The Mac's held space bar: show the original for as long as it is held.
    /// A two-finger tap is the closest thing a hand can do on glass, and it is
    /// what Photos uses for the same purpose.
    @objc private func handleTwoFingerTap(_ g: UITapGestureRecognizer) {
        guard let host else { return }
        host.toggledOriginal(!host.renderer.showOriginal)
    }

    // MARK: pinch

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard let host, let renderer else { return }
        guard host.tool != .crop else { return }   // fitted and locked
        let p = g.location(in: self)
        switch g.state {
        case .began:
            g.scale = 1
        case .changed:
            if host.placementZoomed(by: Double(g.scale), at: unclampedNormalised(p)) {
                g.scale = 1
                return
            }
            renderer.viewport.zoom(by: g.scale, about: p)
            g.scale = 1
            host.viewportChanged()
            scheduleDraw()
        default:
            break
        }
    }

    // MARK: pan

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let host, let renderer else { return }
        let p = g.location(in: self)

        switch g.state {
        case .began:
            becomeFirstResponder()
            beginDrag(at: p, host: host, renderer: renderer)
        case .changed:
            continueDrag(at: p, host: host, renderer: renderer)
        case .ended, .cancelled, .failed:
            endDrag(at: p, host: host, renderer: renderer)
        default:
            break
        }
    }

    private func beginDrag(at p: CGPoint, host: CanvasHost, renderer: Renderer) {
        pressPoint = p
        switch host.tool {
        case .crop:
            let g = host.geometry
            let size = host.sourceImageSize
            let tolerance = Self.handleGrab / max(renderer.viewport.scale, 1e-6)
            let n = sourcePoint(p)
            // `Geometry.handle` answers `.body` for a point inside the frame
            // and an edge/corner handle for a point on one — the same call the
            // Mac's mousedown makes, so "drag the frame" and "drag a grip" are
            // decided in one place rather than by two hit tests that could
            // disagree. No handle at all means the pointer is off the frame,
            // and off the frame is the rotate drag.
            if let handle = g.handle(at: n, in: size, tolerance: tolerance) {
                let c = g.centre
                if handle == .body {
                    drag = .move(origin: g, grab: CGSize(width: n.x - c.x, height: n.y - c.y))
                } else {
                    drag = .resize(handle, origin: g,
                                   grab: CGSize(width: n.x - c.x, height: n.y - c.y))
                }
                return
            }
            // A rotation in flight holds the view still until this drag ends,
            // so the picture never rescales under the hand that is turning it.
            let centre = viewPoint(ofSource: g.centre)
            renderer.beginRotation()
            drag = .rotate(origin: g, centre: centre,
                           from: Self.bearing(from: centre, to: p))
        default:
            if let h = maskHandle(near: p) { drag = .mask(h); return }
            if host.placementBegan(at: unclampedNormalised(p)) { drag = .placement; return }
            drag = .pan(from: p)
        }
    }

    private func continueDrag(at p: CGPoint, host: CanvasHost, renderer: Renderer) {
        switch drag {
        case .pan(let from):
            renderer.viewport.pan(by: CGSize(width: p.x - from.x, height: p.y - from.y))
            drag = .pan(from: p)
            host.viewportChanged()
            scheduleDraw()
        case .resize(let handle, let origin, _):
            let size = host.sourceImageSize
            host.geometryChanged(origin.resized(handle: handle,
                                                to: origin.unrotated(clampedSourcePoint(p), in: size),
                                                in: size))
        case .move(let origin, let grab):
            let n = sourcePoint(p)
            let target = CGPoint(x: n.x - grab.width, y: n.y - grab.height)
            let delta = CGSize(width: target.x - origin.centre.x, height: target.y - origin.centre.y)
            host.geometryChanged(origin.moved(by: delta, in: host.sourceImageSize))
        case .rotate(let origin, let centre, let from):
            var delta = Self.bearing(from: centre, to: p) - from
            while delta > 180 { delta -= 360 }
            while delta <= -180 { delta += 360 }
            host.geometryChanged(origin.straightened(to: origin.angle - delta, in: host.sourceImageSize))
        case .mask(let h):
            guard let out = imagePoint(p) else { return }
            host.maskHandleDragged(h, to: host.geometry.sourcePoint(forOutput: out,
                                                                    imageSize: host.sourceImageSize))
        case .placement:
            host.placementMoved(to: unclampedNormalised(p))
        case .none:
            break
        }
    }

    private func endDrag(at p: CGPoint, host: CanvasHost, renderer: Renderer) {
        if case .placement = drag { host.placementEnded() }
        // A tap that did not move is a click: the Mac's 3 pt rule, and the way
        // a pair's empty hole is chosen and a mask is selected.
        if let down = pressPoint, hypot(p.x - down.x, p.y - down.y) < 3,
           host.tool != .crop, let n = imagePoint(p) {
            host.clicked(normalised: n)
        }
        pressPoint = nil
        drag = .none
        if renderer.rotationHeld { renderer.endRotation() }
        host.straightenPreview(nil)
        scheduleDraw()
    }

    // MARK: rotate

    /// Two fingers turning the photograph straightens it, the way Photos and
    /// every iPad photo editor do it. Only in the crop tool: straighten is a
    /// property of the frame, and outside that tool the gesture has nothing to
    /// act on.
    @objc private func handleRotate(_ g: UIRotationGestureRecognizer) {
        guard let host else { return }
        guard host.tool == .crop else { return }
        switch g.state {
        case .began:
            rotationStart = (host.geometry, host.geometry.angle)
            host.renderer.beginRotation()
        case .changed:
            guard let start = rotationStart else { return }
            let degrees = Double(g.rotation) * 180 / .pi
            host.geometryChanged(start.origin.straightened(to: start.angle + degrees,
                                                           in: host.sourceImageSize))
        case .ended, .cancelled, .failed:
            rotationStart = nil
            if host.renderer.rotationHeld { host.renderer.endRotation() }
        default:
            break
        }
    }

    // MARK: keyboard

    /// True while the hardware keyboard's space bar is down and this view put
    /// the canvas into "showing the original". Held in the view rather than
    /// read back from the renderer, because the renderer's flag can also be
    /// set by the toolbar — releasing space must not undo that.
    private var spaceShowsOriginal = false

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let host else { return super.pressesBegan(presses, with: event) }
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            switch key.keyCode {
            case .keyboardSpacebar:
                host.toggledOriginal(true)
                spaceShowsOriginal = true
                handled = true
            case .keyboardLeftArrow:
                host.stepFrame(-1); handled = true
            case .keyboardRightArrow:
                host.stepFrame(1); handled = true
            case .keyboardZ:
                host.renderer.viewport.toggleHundred(about: CGPoint(x: bounds.midX, y: bounds.midY))
                host.viewportChanged(); scheduleDraw(); handled = true
            case .keyboardReturnOrEnter, .keypadEnter:
                host.commitCrop(); handled = true
            case .keyboardEscape:
                host.cancelCrop(); handled = true
            default:
                break
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let host else { return super.pressesEnded(presses, with: event) }
        for press in presses where press.key?.keyCode == .keyboardSpacebar {
            if spaceShowsOriginal {
                host.toggledOriginal(false)
                spaceShowsOriginal = false
            }
        }
        super.pressesEnded(presses, with: event)
    }
}

// MARK: - gesture arbitration

extension PadCanvasView: UIGestureRecognizerDelegate {
    /// Pinch and rotation run together (they are two fingers each and a user
    /// doing one is usually doing the other); the one-finger pan concedes to
    /// both.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Pinch and rotation are the only pair that must run together: both are
        // two-finger gestures and a user straightening a horizon usually also
        // nudges the zoom. Everything else stays exclusive — the one-finger pan
        // sets `maximumNumberOfTouches = 1`, so it cannot physically overlap
        // them, and letting a tap recognise alongside a pan would fire a click
        // at the end of every drag.
        let multi: (UIGestureRecognizer) -> Bool = {
            $0 is UIPinchGestureRecognizer || $0 is UIRotationGestureRecognizer
        }
        return multi(g) && multi(other)
    }
}

// MARK: - MTKViewDelegate

/// `MTKViewDelegate` is an `@objc` protocol, so its requirements are
/// nonisolated, while `MTKView` and this subclass are `@MainActor`. Xcode's
/// macOS build gets away with declaring the conformance on the class because
/// MetalKit's macOS SDK is not annotated; the iOS 27 SDK is, so the conformance
/// has to say `@preconcurrency` and each callback has to cross the isolation
/// boundary by hand.
///
/// Both callbacks arrive on the main thread by construction — `MTKView` drives
/// them from the display link and from `setNeedsDisplay` — so
/// `assumeIsolated` states a fact rather than hoping for one.
extension PadCanvasView: @preconcurrency MTKViewDelegate {
    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated { syncViewport() }
    }

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { host?.renderer.draw(in: view) }
    }
}
