import SwiftUI
import UIKit

/// UIKit touch layer over the trace canvas — the single gesture authority.
/// SwiftUI (as of iOS 26) has no finger-count gestures, so everything that
/// depends on finger count lives here:
/// - pinch → `onPinch(scaleDelta, centroid)` (always)
/// - two-finger drag → `onPan(delta)` (always)
/// - one-finger drag/tap → eraser samples while `eraserActive`, else pan
/// - two-finger tap → `onTwoFingerTap` (always)
struct TouchOverlay: UIViewRepresentable {
    var eraserActive: Bool
    /// (previous, current) in view coordinates; previous is nil at stroke start.
    var onErase: (CGPoint?, CGPoint) -> Void
    /// The erase stroke lifted — commit whatever was collected.
    var onEraseEnd: () -> Void
    /// A second finger arrived while a one-finger stroke was barely underway:
    /// discard that stroke, the gesture was really a zoom or a pan.
    var onEraseCancel: () -> Void
    var onPan: (CGPoint) -> Void
    var onPinch: (CGFloat, CGPoint) -> Void
    var onTwoFingerTap: () -> Void
    /// Single tap while the eraser is off (the refine screen's prompt taps).
    var onSingleTap: ((CGPoint) -> Void)? = nil

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let coordinator = context.coordinator

        let singlePan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.singlePan(_:)))
        singlePan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(singlePan)

        let singleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.singleTap(_:)))
        singleTap.numberOfTouchesRequired = 1
        view.addGestureRecognizer(singleTap)

        let doublePan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.doublePan(_:)))
        doublePan.minimumNumberOfTouches = 2
        doublePan.maximumNumberOfTouches = 2
        view.addGestureRecognizer(doublePan)

        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.pinch(_:)))
        view.addGestureRecognizer(pinch)

        let twoFingerTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.twoFingerTap))
        twoFingerTap.numberOfTouchesRequired = 2
        view.addGestureRecognizer(twoFingerTap)

        for recognizer in [singlePan, singleTap, doublePan, pinch, twoFingerTap] {
            recognizer.delegate = coordinator
        }
        coordinator.singleTouchRecognizers = [singlePan, singleTap]
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        // The navigation back-swipe starts at the same left edge a long
        // point-drag or lasso can reach; while an edit mode owns one-finger
        // input, the pop gesture must not steal the screen.
        context.coordinator.setPopGesture(suppressed: eraserActive, for: view)
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.setPopGesture(suppressed: false, for: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TouchOverlay
        var singleTouchRecognizers: [UIGestureRecognizer] = []
        private var lastErasePoint: CGPoint?
        /// True while a one-finger capture (erase stroke or point drag) is
        /// mid-flight. A stray second touch — a stretched palm on a long
        /// drag — must not start panning/zooming the canvas underneath it.
        private var singleCaptureActive = false
        /// When the one-finger capture began. A second finger arriving within
        /// `handoverWindow` means the user was starting a two-finger gesture
        /// all along; arriving later is a palm settling mid-stroke, which must
        /// not hijack the drawing.
        private var singleCaptureStart = ContinuousClock.now
        private static let handoverWindow = Duration.milliseconds(350)

        /// Gives up an in-flight one-finger stroke in favour of the
        /// two-finger gesture now starting, if it is young enough.
        private func yieldSingleCaptureIfFresh() -> Bool {
            guard singleCaptureActive else { return true }
            guard singleCaptureStart.duration(to: .now) < Self.handoverWindow else { return false }
            singleCaptureActive = false
            lastErasePoint = nil
            parent.onEraseCancel()
            return true
        }
        private weak var suppressedPopGesture: UIGestureRecognizer?

        init(_ parent: TouchOverlay) { self.parent = parent }

        func setPopGesture(suppressed: Bool, for view: UIView) {
            if suppressed {
                guard suppressedPopGesture == nil,
                      let pop = Self.navigationController(for: view)?.interactivePopGestureRecognizer,
                      pop.isEnabled else { return }
                pop.isEnabled = false
                suppressedPopGesture = pop
            } else if let pop = suppressedPopGesture {
                pop.isEnabled = true
                suppressedPopGesture = nil
            }
        }

        private static func navigationController(for view: UIView) -> UINavigationController? {
            var responder: UIResponder? = view
            while let current = responder {
                if let controller = current as? UIViewController {
                    if let navigation = controller as? UINavigationController { return navigation }
                    if let navigation = controller.navigationController { return navigation }
                }
                responder = current.next
            }
            return nil
        }

        @objc func singlePan(_ recognizer: UIPanGestureRecognizer) {
            if parent.eraserActive {
                let location = recognizer.location(in: recognizer.view)
                switch recognizer.state {
                case .began:
                    singleCaptureActive = true
                    singleCaptureStart = .now
                    lastErasePoint = nil
                    parent.onErase(nil, location)
                    lastErasePoint = location
                case .changed:
                    parent.onErase(lastErasePoint, location)
                    lastErasePoint = location
                default:
                    singleCaptureActive = false
                    lastErasePoint = nil
                    parent.onEraseEnd()
                }
            } else {
                let delta = recognizer.translation(in: recognizer.view)
                recognizer.setTranslation(.zero, in: recognizer.view)
                parent.onPan(delta)
            }
        }

        @objc func singleTap(_ recognizer: UITapGestureRecognizer) {
            let location = recognizer.location(in: recognizer.view)
            if parent.eraserActive {
                parent.onErase(nil, location)
                parent.onEraseEnd()
            } else {
                parent.onSingleTap?(location)
            }
        }

        @objc func doublePan(_ recognizer: UIPanGestureRecognizer) {
            guard yieldSingleCaptureIfFresh() else { return }
            guard recognizer.state == .began || recognizer.state == .changed else { return }
            let delta = recognizer.translation(in: recognizer.view)
            recognizer.setTranslation(.zero, in: recognizer.view)
            parent.onPan(delta)
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            guard yieldSingleCaptureIfFresh() else { return }
            guard recognizer.state == .began || recognizer.state == .changed else { return }
            parent.onPinch(recognizer.scale, recognizer.location(in: recognizer.view))
            recognizer.scale = 1
        }

        @objc func twoFingerTap() {
            guard yieldSingleCaptureIfFresh() else { return }
            parent.onTwoFingerTap()
        }

        /// Pinch and two-finger pan must run together for natural zoom-drag.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            !(gestureRecognizer is UITapGestureRecognizer) && !(other is UITapGestureRecognizer)
        }
    }
}
