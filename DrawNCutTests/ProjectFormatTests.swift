import Foundation
import Testing
@testable import DrawNCut

/// `project.json` is the user's own file, sitting in Documents and surviving
/// every app update. Anything that stops an older one decoding loses their
/// drawings, so the format's backward compatibility is pinned here rather
/// than trusted to `Codable` staying convenient.
struct ProjectFormatTests {

    private func decode(_ json: String) throws -> DrawingProject {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DrawingProject.self, from: Data(json.utf8))
    }

    /// The shape written before trace versions, thresholds or mask prompts
    /// existed. Every field added since must be optional.
    @Test func aProjectFileFromTheFirstReleaseStillOpens() throws {
        let project = try decode("""
        {
          "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
          "title": "Fish",
          "createdAt": "2026-08-01T10:00:00Z",
          "updatedAt": "2026-08-01T10:00:00Z",
          "traceVersions": []
        }
        """)
        #expect(project.title == "Fish")
        #expect(project.traceVersions.isEmpty)
        #expect(project.maskPrompts == nil)
        #expect(project.scale == nil)
    }

    @Test func aProjectWithTraceVersionsButNoMaskPromptsStillOpens() throws {
        let project = try decode("""
        {
          "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
          "title": "Deer",
          "createdAt": "2026-08-01T10:00:00Z",
          "updatedAt": "2026-08-02T10:00:00Z",
          "traceVersions": [
            {
              "id": "5F2504E0-4F89-11D3-9A0C-0305E82C3301",
              "number": 1,
              "createdAt": "2026-08-02T10:00:00Z",
              "detail": 0.7,
              "pathsFilename": "v1.json"
            }
          ],
          "activeTraceVersionID": "5F2504E0-4F89-11D3-9A0C-0305E82C3301"
        }
        """)
        #expect(project.traceVersions.count == 1)
        #expect(project.activeTraceVersion?.number == 1)
        #expect(project.maskPrompts == nil)
    }

    @MainActor
    @Test func aProjectRoundTripsThroughTheStoresEncoding() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "Format-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProjectStore(rootURL: root)
        var project = try store.create(title: "Round Trip")
        project.maskPrompts = [MaskPrompt(x: 0.25, y: 0.75, isSubject: false)]
        project.scale = ScaleInfo(millimetersPerPixel: 0.13, source: .quarter)
        try store.save(project)

        let reopened = ProjectStore(rootURL: root)
        try reopened.loadAll()
        let loaded = try #require(reopened.projects.first)
        #expect(loaded.title == "Round Trip")
        #expect(loaded.maskPrompts == project.maskPrompts)
        #expect(loaded.scale == project.scale)
    }
}

/// A saved trace version is the other user-owned file. Older ones predate the
/// Smoothing slider, the Threshold slider and frozen geometry, and each of
/// those must default rather than fail.
struct TraceSnapshotFormatTests {

    private func decode(_ json: String) throws -> TraceSnapshot {
        try JSONDecoder().decode(TraceSnapshot.self, from: Data(json.utf8))
    }

    @Test func theOldestSnapshotIsJustADetailValue() throws {
        let snapshot = try decode(#"{"detail":0.7}"#)
        #expect(snapshot.detail == 0.7)
        #expect(snapshot.smoothness == nil)
        #expect(snapshot.threshold == nil)
        #expect(snapshot.eraseTaps == nil)
        #expect(snapshot.eraseShapes == nil)
        #expect(snapshot.promotedCuts == nil)
    }

    @Test func legacyEraseAndCutTapsStillDecode() throws {
        let snapshot = try decode("""
        {"detail":0.6,"eraseTaps":[[10,20],[30,40,15]],"cutTaps":[[50,60]]}
        """)
        #expect(snapshot.eraseTaps?.count == 2)
        #expect(snapshot.cutTaps?.count == 1)
    }

    @Test func aCurrentSnapshotCarriesEverySlider() throws {
        let encoded = try JSONEncoder().encode(
            TraceSnapshot(detail: 0.8, outlineDetail: 0.6, outlineSmoothness: 0.5,
                          smoothness: 0.4, threshold: 0.9))
        let snapshot = try JSONDecoder().decode(TraceSnapshot.self, from: encoded)
        #expect(snapshot.detail == 0.8)
        #expect(snapshot.smoothness == 0.4)
        #expect(snapshot.threshold == 0.9)
        #expect(snapshot.outlineDetail == 0.6)
    }
}
