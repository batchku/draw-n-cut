import CoreGraphics
import Foundation
import simd

/// An ellipse, as a coin looks once the camera is not directly above it.
struct FittedEllipse: Equatable {
    var center: SIMD2<Double>
    /// Half the long axis, in pixels.
    var semiMajor: Double
    /// Half the short axis, in pixels.
    var semiMinor: Double
    /// Angle of the major axis, radians, measured from +x toward +y.
    var angle: Double

    /// 1 when the coin is seen square on, falling toward 0 as it tilts away.
    /// This is what carries the tilt: a circle's foreshortening happens only
    /// along one direction, and that direction is the minor axis.
    var axisRatio: Double { semiMajor > 0 ? semiMinor / semiMajor : 0 }

    /// The tilt of the coin's plane away from facing the camera, radians.
    var tilt: Double { acos(min(1, max(0, axisRatio))) }

    /// Unit vector along the major axis — the direction that is *not*
    /// foreshortened.
    var majorAxis: SIMD2<Double> { SIMD2(cos(angle), sin(angle)) }
    var minorAxis: SIMD2<Double> { SIMD2(-sin(angle), cos(angle)) }
}

/// Fits an ellipse to a closed contour by its area moments.
///
/// Moments rather than an algebraic conic fit (Fitzgibbon and friends):
/// a conic fit needs a generalized eigen solver, and it fits the *outline*,
/// so a few stray contour points drag the whole conic. Area moments have a
/// closed form, describe the region the contour encloses, and degrade
/// gracefully — a slightly ragged coin edge moves the answer by a fraction of
/// a pixel instead of throwing the fit off entirely.
enum EllipseFit {
    /// - Parameter polygon: a closed contour, in order, not repeating the
    ///   first point at the end.
    static func fit(polygon: [SIMD2<Double>]) -> FittedEllipse? {
        guard polygon.count >= 5 else { return nil }

        // Green's theorem over the polygon edges: area, centroid, and the
        // second moments, all exact for the enclosed region.
        var area = 0.0
        var cx = 0.0, cy = 0.0
        var m20 = 0.0, m11 = 0.0, m02 = 0.0
        for i in polygon.indices {
            let p = polygon[i]
            let q = polygon[(i + 1) % polygon.count]
            let cross = p.x * q.y - q.x * p.y
            area += cross
            cx += (p.x + q.x) * cross
            cy += (p.y + q.y) * cross
            m20 += (p.x * p.x + p.x * q.x + q.x * q.x) * cross
            m11 += (2 * p.x * p.y + p.x * q.y + q.x * p.y + 2 * q.x * q.y) * cross
            m02 += (p.y * p.y + p.y * q.y + q.y * q.y) * cross
        }
        area /= 2
        guard abs(area) > 1e-9 else { return nil }
        cx /= 6 * area
        cy /= 6 * area
        m20 = m20 / (12 * area) - cx * cx
        m11 = m11 / (24 * area) - cx * cy
        m02 = m02 / (12 * area) - cy * cy

        // Eigenvalues of the 2x2 covariance, closed form. For a uniformly
        // filled ellipse the variance along a principal axis is (semi/2)^2,
        // so the semi-axis is twice the standard deviation.
        let mean = (m20 + m02) / 2
        let diff = (m20 - m02) / 2
        let spread = (diff * diff + m11 * m11).squareRoot()
        let major = mean + spread
        let minor = mean - spread
        guard major > 0, minor > 0 else { return nil }

        return FittedEllipse(
            center: SIMD2(cx, cy),
            semiMajor: 2 * major.squareRoot(),
            semiMinor: 2 * minor.squareRoot(),
            angle: 0.5 * atan2(2 * m11, m20 - m02)
        )
    }

    /// How far the contour strays from the fitted ellipse, as a fraction of
    /// the semi-major axis. A real coin edge sits under a few percent; a
    /// drawn squiggle or a rounded-off rectangle does not.
    ///
    /// This is the gate that separates a coin from anything else roughly
    /// blobby, so it is measured rather than assumed.
    static func residual(of polygon: [SIMD2<Double>], to ellipse: FittedEllipse) -> Double {
        guard ellipse.semiMajor > 0, ellipse.semiMinor > 0, !polygon.isEmpty else { return .infinity }
        let cosA = cos(-ellipse.angle), sinA = sin(-ellipse.angle)
        var sum = 0.0
        for point in polygon {
            let d = point - ellipse.center
            // Into the ellipse's own frame, then onto the unit circle.
            let x = (d.x * cosA - d.y * sinA) / ellipse.semiMajor
            let y = (d.x * sinA + d.y * cosA) / ellipse.semiMinor
            let r = (x * x + y * y).squareRoot()
            sum += (r - 1) * (r - 1)
        }
        return (sum / Double(polygon.count)).squareRoot()
    }
}
