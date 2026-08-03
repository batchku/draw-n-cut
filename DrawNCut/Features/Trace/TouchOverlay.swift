import SwiftUI
import UIKit

/// UIKit touch layer over the trace canvas. SwiftUI (as of iOS 26) has no
/// finger-count gestures, so eraser sweeps and the two-finger undo live here.
/// - One-finger tap or drag → `onErase(point)` per touch sample, only while
///   `eraserActive` (otherwise those touches are ignored entirely).
/// - Two-finger tap → `onTwoFingerTap` (always active).
struct TouchOverlay: UIViewRepresentable {
    var eraserActive: Bool
    var onErase: (CGPoint) -> Void
    var onTwoFingerTap: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.numberOfTouchesRequired = 1
        view.addGestureRecognizer(tap)

        let twoFinger = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.twoFingerTap))
        twoFinger.numberOfTouchesRequired = 2
        view.addGestureRecognizer(twoFinger)

        context.coordinator.singleTouchRecognizers = [pan, tap]
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        for recognizer in context.coordinator.singleTouchRecognizers {
            recognizer.isEnabled = eraserActive
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: TouchOverlay
        var singleTouchRecognizers: [UIGestureRecognizer] = []

        init(_ parent: TouchOverlay) { self.parent = parent }

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                parent.onErase(recognizer.location(in: recognizer.view))
            default:
                break
            }
        }

        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            parent.onErase(recognizer.location(in: recognizer.view))
        }

        @objc func twoFingerTap() {
            parent.onTwoFingerTap()
        }
    }
}
