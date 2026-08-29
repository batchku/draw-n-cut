import CoreGraphics
import Testing
@testable import DrawNCut

/// Two-finger pan must move the drawing freely. Reported from the device:
/// "I'm not able to move the image around freely; at some points it hits a
/// limit." The old rule pinned the drawing's edges to the viewport's, so at
/// fit zoom it could not be moved at all.
struct CanvasPanTests {
    private let viewport = CGSize(width: 390, height: 700)
    private let content = CGSize(width: 300, height: 500)

    private func settled(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CanvasPan.settled(
            contentOrigin: CGPoint(x: x, y: y), contentSize: content, viewport: viewport)
    }

    @Test func panIsFreeAtFitZoom() {
        // The specific complaint: unzoomed, the drawing would not budge.
        let moved = settled(-120, 240)
        #expect(moved == CGPoint(x: -120, y: 240))
    }

    @Test func drawingCanBeMovedWellBeyondTheViewportEdges() {
        // Working a corner against the screen edge means most of the drawing
        // hangs off. That has to be allowed.
        #expect(settled(-240, -440) == CGPoint(x: -240, y: -440))
        #expect(settled(330, 640) == CGPoint(x: 330, y: 640))
    }

    @Test func drawingCannotBeLostOffScreen() {
        let keep = CanvasPan.minimumVisible
        // Flung far past every edge, a sliver stays reachable.
        let offLeft = settled(-10_000, 0)
        #expect(offLeft.x == keep - content.width)
        let offRight = settled(10_000, 0)
        #expect(offRight.x == viewport.width - keep)
        let offTop = settled(0, -10_000)
        #expect(offTop.y == keep - content.height)
        let offBottom = settled(0, 10_000)
        #expect(offBottom.y == viewport.height - keep)
    }

    @Test func aDrawingNarrowerThanTheMarginStillPans() {
        // keep is capped at the content's own extent, or the allowed range
        // would invert and the drawing would jam at one spot.
        let tiny = CGSize(width: 20, height: 20)
        let free = CanvasPan.settled(
            contentOrigin: CGPoint(x: 200, y: 300), contentSize: tiny, viewport: viewport)
        #expect(free == CGPoint(x: 200, y: 300))
        let pinned = CanvasPan.settled(
            contentOrigin: CGPoint(x: 10_000, y: 0), contentSize: tiny, viewport: viewport)
        #expect(pinned.x == viewport.width - tiny.width)
    }

    @Test func zoomCanPullBackBelowFit() {
        // Another felt limit: zoom could not go under 1, so the drawing could
        // never be made smaller than the screen.
        #expect(CanvasPan.clampedZoom(0.7) == 0.7)
        #expect(CanvasPan.clampedZoom(0.1) == CanvasPan.minimumZoom)
        #expect(CanvasPan.clampedZoom(99) == CanvasPan.maximumZoom)
    }
}
