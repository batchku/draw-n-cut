import Foundation

/// Writes DXF R12 (AC1009) — the dialect with the broadest laser-software
/// support (LightBurn, Glowforge, xTool). Millimeter units, POLYLINE entities,
/// paths placed on a CUT or ENGRAVE layer by their role.
enum DXFWriter {
    static let cutLayer = "CUT"
    static let engraveLayer = "ENGRAVE"

    /// - Parameter paths: paths in millimeters, y-up.
    static func dxf(for paths: [VectorPath]) -> String {
        var lines: [String] = []

        func group(_ code: Int, _ value: String) {
            lines.append(String(code))
            lines.append(value)
        }
        func coord(_ value: Double) -> String {
            String(format: "%.4f", value)
        }

        // HEADER: declare version and millimeter units.
        group(0, "SECTION"); group(2, "HEADER")
        group(9, "$ACADVER"); group(1, "AC1009")
        group(9, "$INSUNITS"); group(70, "4")
        group(0, "ENDSEC")

        // TABLES: one layer per role. Color 1 = red (cut), 5 = blue (engrave).
        group(0, "SECTION"); group(2, "TABLES")
        group(0, "TABLE"); group(2, "LAYER"); group(70, "2")
        for (name, color) in [(cutLayer, 1), (engraveLayer, 5)] {
            group(0, "LAYER")
            group(2, name)
            group(70, "0")
            group(62, String(color))
            group(6, "CONTINUOUS")
        }
        group(0, "ENDTAB")
        group(0, "ENDSEC")

        // ENTITIES: each path as a POLYLINE + VERTEX list + SEQEND.
        group(0, "SECTION"); group(2, "ENTITIES")
        for path in paths where path.points.count >= 2 {
            let layer = path.role == .cut ? cutLayer : engraveLayer
            group(0, "POLYLINE")
            group(8, layer)
            group(66, "1")
            group(70, path.isClosed ? "1" : "0")
            for point in path.points {
                group(0, "VERTEX")
                group(8, layer)
                group(10, coord(point.x))
                group(20, coord(point.y))
                group(30, "0.0")
            }
            group(0, "SEQEND")
            group(8, layer)
        }
        group(0, "ENDSEC")

        group(0, "EOF")
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
