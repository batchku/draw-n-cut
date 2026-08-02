import CoreGraphics
import Foundation
import simd

/// What a traced element *is*, physically — which determines what the laser
/// may do with it. Open strokes are never cut, only engraved.
enum ElementKind: String, Codable {
    /// Pen lines: the default. Engraved as centerlines.
    case stroke
    /// A small filled mark (an eye). Engraved as a tiny loop.
    case dot
    /// A solidly filled region. Engrave-fill candidate.
    case blob
    /// Dense back-and-forth pen travel (a scribbled-in area). Engrave-fill
    /// candidate; the Detail slider collapses it early.
    case scribbleFill
}

struct ClassifiedElement: Identifiable {
    let element: TracedElement
    let kind: ElementKind
    /// Index into `Classification.clusters`; one cluster ≈ one drawing.
    var clusterIndex: Int

    var id: UUID { element.id }
}

/// A spatial group of elements — on a multi-drawing page, one cluster per
/// drawing (plus its label). The subject cluster is chosen by the SAM mask
/// in-app; classification itself stays subject-agnostic.
struct ElementCluster {
    var elementIDs: [UUID]
    var boundingBox: CGRect
    var totalInkArea: Int
}

struct Classification {
    var elements: [ClassifiedElement]
    var clusters: [ElementCluster]

    func cluster(of element: TracedElement) -> Int? {
        elements.first { $0.element.id == element.id }?.clusterIndex
    }
}

enum ElementClassifier {
    static func classify(_ result: TraceResult) -> Classification {
        let elements = result.elements
        let diagonal = hypot(result.imageSize.width, result.imageSize.height)

        let kinds = elements.map { kind(of: $0, imageDiagonal: diagonal) }
        let clusterIndices = clusterAssignments(elements: elements, gap: 0.015 * diagonal)

        var clusters: [ElementCluster] = []
        let clusterCount = (clusterIndices.max() ?? -1) + 1
        for c in 0..<clusterCount {
            let members = elements.indices.filter { clusterIndices[$0] == c }
            let box = members.map { elements[$0].boundingBox }.reduce(CGRect.null) { $0.union($1) }
            clusters.append(ElementCluster(
                elementIDs: members.map { elements[$0].id },
                boundingBox: box,
                totalInkArea: members.reduce(0) { $0 + elements[$1].inkArea }
            ))
        }

        let classified = elements.indices.map { i in
            ClassifiedElement(element: elements[i], kind: kinds[i], clusterIndex: clusterIndices[i])
        }
        return Classification(elements: classified, clusters: clusters)
    }

    // MARK: - Kind

    static func kind(of element: TracedElement, imageDiagonal: Double) -> ElementKind {
        let bbox = element.boundingBox
        let bboxArea = Double(bbox.width * bbox.height)
        let maxSide = Double(max(bbox.width, bbox.height))
        let minSide = Double(min(bbox.width, bbox.height))
        let density = bboxArea > 0 ? Double(element.inkArea) / bboxArea : 1
        let perimeter = 2 * (Double(bbox.width) + Double(bbox.height))

        // Tiny compact mark: a few pen widths across AND small in absolute
        // terms — a filled shape of real size is a blob, not a dot.
        if maxSide <= 5 * element.estimatedStrokeWidth && maxSide <= 0.03 * imageDiagonal && density > 0.4 {
            return .dot
        }

        // Solid fill: ink covers most of the bbox and the "stroke" is as fat
        // as the shape itself.
        if density > 0.55 && element.estimatedStrokeWidth > 0.25 * minSide {
            return .blob
        }

        // Scribble: far more pen travel than the region's size explains.
        if density > 0.30 && element.totalLength > 2.5 * perimeter {
            return .scribbleFill
        }

        return .stroke
    }

    // MARK: - Clustering

    /// Union-find over elements; two elements join when their bboxes, each
    /// expanded by `gap`, intersect.
    private static func clusterAssignments(elements: [TracedElement], gap: Double) -> [Int] {
        var parent = Array(elements.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        func union(_ a: Int, _ b: Int) {
            parent[find(a)] = find(b)
        }

        let expanded = elements.map { $0.boundingBox.insetBy(dx: -gap, dy: -gap) }
        for i in elements.indices {
            for j in (i + 1)..<elements.count where expanded[i].intersects(expanded[j]) {
                union(i, j)
            }
        }

        // Compact root ids to 0..<k.
        var rootToCluster: [Int: Int] = [:]
        return elements.indices.map { i in
            let root = find(i)
            if let existing = rootToCluster[root] { return existing }
            let next = rootToCluster.count
            rootToCluster[root] = next
            return next
        }
    }
}
