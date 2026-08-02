import Foundation

/// What the laser should do with a path. Serialized into trace-version files
/// and mapped to a DXF layer on export.
enum PathRole: String, Codable {
    case cut
    case engrave
}

/// One traced path in real-world millimeters, y-up (CAD convention).
/// Image-space paths (y-down, pixels) must be scaled and flipped before they
/// become a VectorPath.
struct VectorPath: Codable, Identifiable, Equatable {
    let id: UUID
    var points: [Point]
    var isClosed: Bool
    var role: PathRole

    struct Point: Codable, Equatable {
        var x: Double
        var y: Double
    }

    init(id: UUID = UUID(), points: [Point], isClosed: Bool, role: PathRole) {
        self.id = id
        self.points = points
        self.isClosed = isClosed
        self.role = role
    }
}
