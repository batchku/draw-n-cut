import Foundation
import Testing
@testable import DrawNCut

@MainActor
struct ProjectStoreTests {
    private func makeStore() throws -> (ProjectStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ProjectStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (ProjectStore(rootURL: root), root)
    }

    @Test func createPersistsProjectFolderAndMetadata() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = try store.create(title: "Dragon")

        #expect(FileManager.default.fileExists(atPath: store.metadataURL(for: project).path))
        #expect(FileManager.default.fileExists(atPath: store.tracesDirectory(for: project).path))
        #expect(FileManager.default.fileExists(atPath: store.exportsDirectory(for: project).path))
        #expect(store.projects.count == 1)
    }

    @Test func loadAllRoundTripsFromDisk() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let created = try store.create(title: "Robot Cat")

        let reloaded = ProjectStore(rootURL: root)
        try reloaded.loadAll()
        #expect(reloaded.projects.map(\.id) == [created.id])
        #expect(reloaded.projects.first?.title == "Robot Cat")
    }

    @Test func traceVersionsAreAppendOnlyAndNumbered() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = try store.create(title: "House")
        let v1 = try store.addTraceVersion(to: project, detail: 0.3, pathsData: Data("paths-1".utf8))
        let v2 = try store.addTraceVersion(to: store.projects[0], detail: 0.8, pathsData: Data("paths-2".utf8))

        let updated = store.projects[0]
        #expect(updated.traceVersions.map(\.number) == [1, 2])
        #expect(updated.activeTraceVersionID == v2.id)
        // Old version's paths file must still exist untouched.
        let v1Data = try Data(contentsOf: store.tracePathsURL(for: v1, in: updated))
        #expect(String(decoding: v1Data, as: UTF8.self) == "paths-1")
    }

    @Test func restoringAPreviousVersionMovesThePointerOnly() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = try store.create(title: "Rocket")
        let v1 = try store.addTraceVersion(to: project, detail: 0.2, pathsData: Data("a".utf8))
        _ = try store.addTraceVersion(to: store.projects[0], detail: 0.9, pathsData: Data("b".utf8))

        try store.setActiveTraceVersion(v1, in: store.projects[0])

        let updated = store.projects[0]
        #expect(updated.activeTraceVersionID == v1.id)
        #expect(updated.traceVersions.count == 2)
        #expect(updated.activeTraceVersion?.detail == 0.2)
    }

    @Test func deleteRemovesFolderAndListing() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = try store.create(title: "Fish")
        let folder = store.directory(for: project)
        try store.delete(project)

        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(store.projects.isEmpty)
    }
}

/// Renaming and resuming a subject selection: the drawing keeps its identity
/// and its selection markers across visits.
@MainActor
struct ProjectIdentityTests {
    private func store() throws -> (ProjectStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "Identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (ProjectStore(rootURL: root), root)
    }

    @Test func renamePersistsAndKeepsTheSameFolder() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try store.create(title: "Drawing 1")
        let folder = store.directory(for: project)

        try store.rename(project, to: "Deer in the Woods")

        #expect(store.projects.first?.title == "Deer in the Woods")
        #expect(store.directory(for: project) == folder, "renaming must not move files")
        let reloaded = ProjectStore(rootURL: root)
        try reloaded.loadAll()
        #expect(reloaded.projects.first?.title == "Deer in the Woods")
    }

    @Test func maskPromptsRoundTripAndClearOnTraceEverything() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try store.create(title: "Fish")

        let prompts = [
            MaskPrompt(x: 0.5, y: 0.25, isSubject: true),
            MaskPrompt(x: 0.1, y: 0.9, isSubject: false),
        ]
        try store.saveMaskPrompts(prompts, in: project)

        let reloaded = ProjectStore(rootURL: root)
        try reloaded.loadAll()
        #expect(reloaded.projects.first?.maskPrompts == prompts)

        // "Trace Everything" abandons the selection, so the markers must go
        // too — otherwise reopening the screen would resurrect a selection
        // the user just discarded.
        try store.saveMaskPrompts([], in: try #require(store.projects.first))
        #expect(store.projects.first?.maskPrompts == nil)
    }
}
