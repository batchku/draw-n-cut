import CoreGraphics

/// Where the drawing is allowed to sit on the canvas.
///
/// Two-finger pan is free: the drawing can be moved anywhere, at any zoom,
/// including all the way off to one side so a far corner can be worked on
/// against the edge of the screen. The previous rule pinned the drawing's
/// edges to the viewport's, which meant it could not be moved at all until
/// zoomed in, and then only within the viewport — it kept hitting a wall.
///
/// The single remaining rule is that the drawing cannot be lost: a sliver
/// stays on screen, so there is always something to drag back. It engages
/// only at the very edge of the gesture's range.
enum CanvasPan {
    /// How much of the drawing stays reachable, in points. Roughly a thumb.
    static let minimumVisible: CGFloat = 60

    /// Zoom range. Below 1 the whole drawing pulls back smaller than the
    /// screen, which is its own kind of "move it out of my way".
    static let minimumZoom: CGFloat = 0.5
    static let maximumZoom: CGFloat = 8

    /// Clamps a content rectangle's origin so it still overlaps the viewport.
    /// Everything short of leaving the screen entirely is allowed through
    /// untouched.
    static func settled(
        contentOrigin origin: CGPoint, contentSize: CGSize, viewport: CGSize
    ) -> CGPoint {
        CGPoint(
            x: settled(origin.x, extent: contentSize.width, viewportExtent: viewport.width),
            y: settled(origin.y, extent: contentSize.height, viewportExtent: viewport.height)
        )
    }

    /// One axis. `keep` never exceeds the content's own extent, or a drawing
    /// narrower than the margin could never satisfy the rule and would jam.
    private static func settled(
        _ origin: CGFloat, extent: CGFloat, viewportExtent: CGFloat
    ) -> CGFloat {
        guard extent > 0, viewportExtent > 0 else { return origin }
        let keep = min(minimumVisible, extent)
        // Far edge must not pass the viewport's near edge, and vice versa.
        let lowest = keep - extent
        let highest = viewportExtent - keep
        guard lowest <= highest else { return origin }
        return min(highest, max(lowest, origin))
    }

    static func clampedZoom(_ zoom: CGFloat) -> CGFloat {
        min(maximumZoom, max(minimumZoom, zoom))
    }
}
