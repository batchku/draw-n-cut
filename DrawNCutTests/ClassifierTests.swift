import CoreGraphics
import Foundation
import Testing
@testable import DrawNCut

struct ClassifierTests {
    @Test func kindsMatchSyntheticShapes() throws {
        let image = TestCanvas.image(size: 400) { ctx in
            // Plain stroke.
            ctx.setLineWidth(4)
            ctx.move(to: CGPoint(x: 20, y: 40)); ctx.addLine(to: CGPoint(x: 180, y: 60))
            ctx.strokePath()
            // Filled blob.
            ctx.fillEllipse(in: CGRect(x: 250, y: 30, width: 80, height: 60))
            // Dot.
            ctx.fillEllipse(in: CGRect(x: 40, y: 200, width: 9, height: 9))
            // Scribble fill: dense zigzag.
            ctx.setLineWidth(3)
            ctx.move(to: CGPoint(x: 220, y: 220))
            for i in 0..<30 {
                ctx.addLine(to: CGPoint(x: 220 + (i % 2 == 0 ? 100 : 0), y: 220 + CGFloat(i) * 4))
            }
            ctx.strokePath()
        }
        let result = try #require(TraceEngine.trace(image: image, detail: 1.0))
        let classification = ElementClassifier.classify(result)
        let kinds = classification.elements.map(\.kind)
        #expect(kinds.contains(.stroke))
        #expect(kinds.contains(.blob))
        #expect(kinds.contains(.dot))
        #expect(kinds.contains(.scribbleFill))
    }

    @Test func distantDrawingsFormSeparateClusters() throws {
        let image = TestCanvas.image(size: 600) { ctx in
            ctx.setLineWidth(4)
            ctx.strokeEllipse(in: CGRect(x: 40, y: 40, width: 100, height: 100))   // drawing A
            ctx.strokeEllipse(in: CGRect(x: 400, y: 400, width: 100, height: 100)) // drawing B
            // A mark near drawing A joins its cluster.
            ctx.move(to: CGPoint(x: 100, y: 150)); ctx.addLine(to: CGPoint(x: 120, y: 170))
            ctx.strokePath()
        }
        let result = try #require(TraceEngine.trace(image: image, detail: 0.9))
        let classification = ElementClassifier.classify(result)
        #expect(classification.clusters.count == 2)
        let sizes = classification.clusters.map(\.elementIDs.count).sorted()
        #expect(sizes == [1, 2])
    }

    @Test func borderCircleAroundDrawingIsFlaggedAsEnclosingLoop() throws {
        let image = TestCanvas.image(size: 400) { ctx in
            ctx.setLineWidth(4)
            // The "drawing": a stick figure-ish set of strokes.
            ctx.move(to: CGPoint(x: 170, y: 150)); ctx.addLine(to: CGPoint(x: 230, y: 150))
            ctx.move(to: CGPoint(x: 200, y: 150)); ctx.addLine(to: CGPoint(x: 200, y: 230))
            ctx.move(to: CGPoint(x: 170, y: 260)); ctx.addLine(to: CGPoint(x: 200, y: 230))
            ctx.move(to: CGPoint(x: 230, y: 260)); ctx.addLine(to: CGPoint(x: 200, y: 230))
            ctx.strokePath()
            ctx.fillEllipse(in: CGRect(x: 193, y: 120, width: 14, height: 14))
            // The border circle drawn around it.
            ctx.strokeEllipse(in: CGRect(x: 100, y: 70, width: 220, height: 240))
        }
        let result = try #require(TraceEngine.trace(image: image, detail: 0.9))
        let classification = ElementClassifier.classify(result)
        let suggestions = NonSubjectDetector.suggestions(for: classification, imageSize: result.imageSize)
        let loops = suggestions.filter { $0.reason == .enclosingLoop }
        #expect(loops.count == 1)
        // And it should point at a specific polyline, not a whole element.
        #expect(loops.first?.polylineIndex != nil)
    }

    @Test func drawnBodyContainingOnlyAnEyeIsNotEnclosing() throws {
        let image = TestCanvas.image(size: 400) { ctx in
            ctx.setLineWidth(4)
            // A fish-like body with a small eye inside...
            ctx.strokeEllipse(in: CGRect(x: 80, y: 140, width: 240, height: 120))
            ctx.fillEllipse(in: CGRect(x: 130, y: 185, width: 12, height: 12))
            // ...and fins/tail strokes outside the body.
            ctx.move(to: CGPoint(x: 320, y: 200)); ctx.addLine(to: CGPoint(x: 370, y: 160))
            ctx.move(to: CGPoint(x: 320, y: 200)); ctx.addLine(to: CGPoint(x: 370, y: 240))
            ctx.move(to: CGPoint(x: 180, y: 140)); ctx.addLine(to: CGPoint(x: 200, y: 100))
            ctx.strokePath()
        }
        let result = try #require(TraceEngine.trace(image: image, detail: 0.9))
        let classification = ElementClassifier.classify(result)
        let loops = NonSubjectDetector.suggestions(for: classification, imageSize: result.imageSize)
            .filter { $0.reason == .enclosingLoop }
        #expect(loops.isEmpty)
    }

    @Test func textRegionsFlagOverlappingElements() throws {
        let image = TestCanvas.image(size: 300) { ctx in
            ctx.setLineWidth(3)
            ctx.strokeEllipse(in: CGRect(x: 100, y: 40, width: 100, height: 100)) // drawing
            ctx.move(to: CGPoint(x: 100, y: 250)); ctx.addLine(to: CGPoint(x: 200, y: 250)) // "label"
            ctx.strokePath()
        }
        let result = try #require(TraceEngine.trace(image: image, detail: 0.9))
        let classification = ElementClassifier.classify(result)
        // Trace space is y-down; the canvas drew the label near the bottom in
        // CG coordinates, which lands near the top of the bitmap — flag a band there.
        let textBand = CGRect(x: 80, y: 30, width: 150, height: 50)
        let flagged = NonSubjectDetector.suggestions(
            for: classification, imageSize: result.imageSize, textRegions: [textBand]
        ).filter { $0.reason == .textLike }
        #expect(flagged.count == 1)
    }
}

struct FixtureClassifierTests {
    @Test func page2CirclesAreDetected() async throws {
        let image = try FixtureTraceTests.fixtureImage("animals-page-2")
        let result = try #require(TraceEngine.trace(image: image, detail: 0.7))
        let classification = ElementClassifier.classify(result)
        let suggestions = NonSubjectDetector.suggestions(for: classification, imageSize: result.imageSize)

        // Page 2 has 6 drawn border circles; several close cleanly in the
        // trace. Require at least 3 found.
        let loops = suggestions.filter { $0.reason == .enclosingLoop }
        #expect(loops.count >= 3, "found \(loops.count) enclosing loops")

        // The scanner edge line on the left must be flagged.
        let edges = suggestions.filter { $0.reason == .edgeArtifact }
        #expect(edges.count >= 1, "found \(edges.count) edge artifacts")
    }

    @Test func handwrittenLabelsAreDetectedByVision() async throws {
        let image = try FixtureTraceTests.fixtureImage("animals-page-1")
        let result = try #require(TraceEngine.trace(image: image, detail: 0.7))
        let classification = ElementClassifier.classify(result)
        let regions = try await TextDetector.textRegions(in: image, scaledTo: result.imageSize)
        let flagged = NonSubjectDetector.suggestions(
            for: classification, imageSize: result.imageSize, textRegions: regions
        ).filter { $0.reason == .textLike }
        // 6 handwritten labels on the page; Vision should catch most.
        #expect(flagged.count >= 3, "flagged \(flagged.count) text elements")
    }
}
