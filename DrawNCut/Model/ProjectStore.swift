import Foundation
import Observation

/// Owns the on-disk library. Layout, one folder per project:
///
///     <root>/Projects/<project-id>/
///         project.json      metadata (DrawingProject)
///         original.jpg      photo as shot
///         rectified.png     perspective-corrected, normalized drawing
///         mask.png          SAM subject mask
///         traces/v<N>.json  vector paths for each trace version
///         exports/*.dxf     exported DXFs
@Observable
@MainActor
final class ProjectStore {
    private(set) var projects: [DrawingProject] = []

    private let rootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameter rootURL: override for tests; defaults to the app's
    ///   Documents directory so files are user-visible in the Files app.
    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? URL.documentsDirectory
        self.encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Loading

    func loadAll() throws {
        let projectsDir = projectsDirectory
        guard FileManager.default.fileExists(atPath: projectsDir.path) else {
            projects = []
            return
        }
        let folders = try FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )
        projects = folders
            .compactMap { folder in
                let metadata = folder.appending(path: "project.json")
                guard let data = try? Data(contentsOf: metadata) else { return nil }
                return try? decoder.decode(DrawingProject.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - CRUD

    @discardableResult
    func create(title: String) throws -> DrawingProject {
        let project = DrawingProject(title: title)
        try FileManager.default.createDirectory(at: tracesDirectory(for: project), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exportsDirectory(for: project), withIntermediateDirectories: true)
        try save(project)
        return project
    }

    func save(_ project: DrawingProject) throws {
        var project = project
        project.updatedAt = .now
        let data = try encoder.encode(project)
        try data.write(to: metadataURL(for: project), options: .atomic)
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.insert(project, at: 0)
        }
        projects.sort { $0.updatedAt > $1.updatedAt }
    }

    func delete(_ project: DrawingProject) throws {
        try FileManager.default.removeItem(at: directory(for: project))
        projects.removeAll { $0.id == project.id }
    }

    // MARK: - Trace versions

    /// Appends a new immutable trace version and makes it active.
    /// `pathsData` is the serialized vector paths the trace produced.
    @discardableResult
    func addTraceVersion(to project: DrawingProject, detail: Double, pathsData: Data) throws -> TraceVersion {
        var project = project
        let version = TraceVersion(number: (project.traceVersions.map(\.number).max() ?? 0) + 1, detail: detail)
        let pathsURL = tracesDirectory(for: project).appending(path: version.pathsFilename)
        try pathsData.write(to: pathsURL, options: .atomic)
        project.traceVersions.append(version)
        project.activeTraceVersionID = version.id
        try save(project)
        return version
    }

    /// Restores a previous version by moving the active pointer; no data is lost.
    func setActiveTraceVersion(_ version: TraceVersion, in project: DrawingProject) throws {
        var project = project
        guard project.traceVersions.contains(version) else { return }
        project.activeTraceVersionID = version.id
        try save(project)
    }

    // MARK: - File locations

    var projectsDirectory: URL { rootURL.appending(path: "Projects") }

    func directory(for project: DrawingProject) -> URL {
        projectsDirectory.appending(path: project.id.uuidString)
    }

    func metadataURL(for project: DrawingProject) -> URL {
        directory(for: project).appending(path: "project.json")
    }

    func originalImageURL(for project: DrawingProject) -> URL {
        directory(for: project).appending(path: "original.jpg")
    }

    func rectifiedImageURL(for project: DrawingProject) -> URL {
        directory(for: project).appending(path: "rectified.png")
    }

    func maskURL(for project: DrawingProject) -> URL {
        directory(for: project).appending(path: "mask.png")
    }

    func tracesDirectory(for project: DrawingProject) -> URL {
        directory(for: project).appending(path: "traces")
    }

    func tracePathsURL(for version: TraceVersion, in project: DrawingProject) -> URL {
        tracesDirectory(for: project).appending(path: version.pathsFilename)
    }

    func exportsDirectory(for project: DrawingProject) -> URL {
        directory(for: project).appending(path: "exports")
    }
}
