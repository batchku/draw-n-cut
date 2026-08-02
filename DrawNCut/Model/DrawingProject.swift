import Foundation

/// One drawing on its way from photo to laser cut. Metadata lives in
/// `project.json` inside the project folder; images, trace paths, and DXFs are
/// sibling files so the whole project is a self-contained, syncable folder.
struct DrawingProject: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var scale: ScaleInfo?
    /// Append-only: every kept Detail-slider setting becomes a new version.
    var traceVersions: [TraceVersion]
    /// Which version the user is currently working from (restoring an old
    /// version just moves this pointer — nothing is deleted).
    var activeTraceVersionID: UUID?

    init(id: UUID = UUID(), title: String, createdAt: Date = .now) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.scale = nil
        self.traceVersions = []
        self.activeTraceVersionID = nil
    }

    var activeTraceVersion: TraceVersion? {
        traceVersions.first { $0.id == activeTraceVersionID } ?? traceVersions.last
    }
}

/// How the drawing's real-world size was established.
struct ScaleInfo: Codable, Equatable {
    enum Source: String, Codable {
        /// A US quarter (24.26 mm) was detected in the photo.
        case quarter
        /// The user typed a size at export.
        case manual
    }

    var millimetersPerPixel: Double
    var source: Source

    /// Diameter of a US quarter, the reference object for auto-calibration.
    static let quarterDiameterMM = 24.26
}

/// One saved trace: the Detail-slider setting plus pointers to the vector
/// paths (and DXF, once exported) it produced. Versions are immutable.
struct TraceVersion: Codable, Identifiable, Equatable {
    let id: UUID
    /// 1-based, in creation order; shown to the user as "v3".
    let number: Int
    let createdAt: Date
    /// The single Detail slider value (0...1) this trace was made with.
    let detail: Double
    /// Filename within the project's `traces/` directory.
    let pathsFilename: String
    /// Filename within the project's `exports/` directory, once exported.
    var dxfFilename: String?

    init(id: UUID = UUID(), number: Int, createdAt: Date = .now, detail: Double) {
        self.id = id
        self.number = number
        self.createdAt = createdAt
        self.detail = detail
        self.pathsFilename = "v\(number).json"
        self.dxfFilename = nil
    }
}
