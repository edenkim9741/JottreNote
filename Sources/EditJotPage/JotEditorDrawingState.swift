@preconcurrency import PencilKit

/// Canonical document ink; page canvases are the only rendering surfaces.
@MainActor
final class JotEditorDrawingState {
    private(set) var committedDrawing = PKDrawing()
    private(set) var committedStrokePageIndices: [Int] = []

    func load(drawing: PKDrawing, strokePageIndices: [Int]) {
        let partition = JotDrawingLayerPartition(drawing: drawing, strokePageIndices: strokePageIndices)
        committedDrawing = partition.combined
        committedStrokePageIndices = partition.combinedPageIndices
    }
    /// Replaces one page while preserving every other page's strokes and the
    /// marker-first ordering used by saving and the native editor.
    @discardableResult
    func replacePage(_ drawing: PKDrawing, at pageIndex: Int) -> Bool {
        var otherStrokes: [PKStroke] = []
        var otherIndices: [Int] = []
        var previousPageStrokes: [PKStroke] = []
        for (index, stroke) in committedDrawing.strokes.enumerated() {
            let owner = committedStrokePageIndices[index]
            if owner == pageIndex {
                previousPageStrokes.append(stroke)
            } else {
                otherStrokes.append(stroke)
                otherIndices.append(owner)
            }
        }
        guard !Self.strokesMatch(previousPageStrokes, drawing.strokes) else { return false }
        otherStrokes.append(contentsOf: drawing.strokes)
        otherIndices.append(contentsOf: repeatElement(pageIndex, count: drawing.strokes.count))
        load(drawing: PKDrawing(strokes: otherStrokes), strokePageIndices: otherIndices)
        return true
    }
    static func drawingsMatch(_ lhs: PKDrawing, _ rhs: PKDrawing) -> Bool {
        lhs == rhs || strokesMatch(lhs.strokes, rhs.strokes)
    }

    private static func strokesMatch(_ lhs: [PKStroke], _ rhs: [PKStroke]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) {
            guard left.randomSeed == right.randomSeed,
                left.transform == right.transform,
                left.ink.inkType == right.ink.inkType,
                left.ink.color.isEqual(right.ink.color),
                left.path.count == right.path.count,
                left.path.creationDate == right.path.creationDate
            else { return false }
            switch (left.mask, right.mask) {
            case (nil, nil): break
            case let (left?, right?): if left.cgPath != right.cgPath { return false }
            default: return false
            }
            // Pressure samples may change while the path keeps its seed and
            // point count. Compare every public sample attribute without
            // serializing or compressing a drawing on the main thread.
            for index in 0..<left.path.count {
                let a = left.path[index]
                let b = right.path[index]
                guard a.location == b.location, a.size == b.size,
                    a.timeOffset == b.timeOffset, a.opacity == b.opacity,
                    a.force == b.force, a.azimuth == b.azimuth, a.altitude == b.altitude
                else { return false }
            }
        }
        return true
    }
}
