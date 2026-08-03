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
    var onPan: (CGPoint) -> Void
    var onPinch: (CGFloat, CGPoint) -> Void
    var onTwoFingerTap: () -> Void

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
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TouchOverlay
        var singleTouchRecognizers: [UIGestureRecognizer] = []
        private var lastErasePoint: CGPoint?

        init(_ parent: TouchOverlay) { self.parent = parent }

        @objc func singlePan(_ recognizer: UIPanGestureRecognizer) {
            if parent.eraserActive {
                let location = recognizer.location(in: recognizer.view)
                switch recognizer.state {
                case .began:
                    lastErasePoint = nil
                    parent.onErase(nil, location)
                    lastErasePoint = location
                case .changed:
                    parent.onErase(lastErasePoint, location)
                    lastErasePoint = location
                default:
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
            guard parent.eraserActive else { return }
            parent.onErase(nil, recognizer.location(in: recognizer.view))
            parent.onEraseEnd()
        }

        @objc func doublePan(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .began || recognizer.state == .changed else { return }
            let delta = recognizer.translation(in: recognizer.view)
            recognizer.setTranslation(.zero, in: recognizer.view)
            parent.onPan(delta)
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            guard recognizer.state == .began || recognizer.state == .changed else { return }
            parent.onPinch(recognizer.scale, recognizer.location(in: recognizer.view))
            recognizer.scale = 1
        }

        @objc func twoFingerTap() {
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
