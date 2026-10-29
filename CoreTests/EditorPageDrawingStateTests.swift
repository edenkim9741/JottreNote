@preconcurrency import PencilKit
import XCTest

@testable import Jottre

@MainActor
final class EditorPageDrawingStateTests: XCTestCase {
    func testOldSingleDrawingLoadsAndRoundTripsWithMasksPressureAndPageOrdering() throws {
        let pen = stroke(seed: 7, force: 0.4)
        let marker = stroke(seed: 8, force: 0.7, marker: true)
        let other = stroke(seed: 9, force: 0.9)
        let old = Jot(
            drawing: PKDrawing(strokes: [pen, marker, other]).dataRepresentation(),
            width: 1_200,
            strokePageIndices: [2, 2, 0]
        )
        let loaded = try PropertyListDecoder().decode(Jot.self, from: PropertyListEncoder().encode(old))
        let state = JotEditorDrawingState()
        state.load(drawing: try PKDrawing(data: loaded.drawing), strokePageIndices: loaded.strokePageIndices)
        XCTAssertEqual(state.drawing(at: 2).strokes.map(\.randomSeed), [7, 8])
        let updated = PKDrawing(strokes: [pen, marker, stroke(seed: 10, force: 0.5)])
        XCTAssertTrue(state.replacePage(updated, at: 2))
        XCTAssertEqual(state.pageRevisions, [2: 1])
        XCTAssertEqual(state.drawing(at: 0).strokes[0].randomSeed, 9)
        let saved = Jot(
            drawing: state.committedDrawing.dataRepresentation(),
            width: 1_200,
            strokePageIndices: state.committedStrokePageIndices
        )
        let restored = try PropertyListDecoder().decode(Jot.self, from: PropertyListEncoder().encode(saved))
        let roundTrip = try PKDrawing(data: restored.drawing)
        XCTAssertEqual(roundTrip.strokes.map(\.randomSeed), [8, 9, 7, 10])
        XCTAssertEqual(restored.strokePageIndices, [2, 0, 2, 2])
        let restoredPen = try XCTUnwrap(roundTrip.strokes.first { $0.randomSeed == 7 })
        XCTAssertEqual(restoredPen.transform, pen.transform)
        XCTAssertEqual(restoredPen.mask?.cgPath, pen.mask?.cgPath)
        for index in 0..<pen.path.count {
            XCTAssertEqual(restoredPen.path[index].force, pen.path[index].force, accuracy: 0.0001)
            XCTAssertEqual(restoredPen.path[index].altitude, pen.path[index].altitude, accuracy: 0.0001)
            XCTAssertEqual(restoredPen.path[index].location, pen.path[index].location)
        }
    }

    func testSameSeedCannotHidePressureMaskOrLassoTransformChanges() {
        let original = stroke(seed: 42, force: 0.4)
        let state = JotEditorDrawingState()
        state.load(drawing: PKDrawing(strokes: [original]), strokePageIndices: [0])
        var modified = stroke(seed: 42, force: 0.8)
        XCTAssertTrue(state.replacePage(PKDrawing(strokes: [modified]), at: 0))
        modified.mask = UIBezierPath(rect: CGRect(x: 0, y: 0, width: 20, height: 20))
        XCTAssertTrue(state.replacePage(PKDrawing(strokes: [modified]), at: 0))
        modified.transform = CGAffineTransform(translationX: 80, y: 120).scaledBy(x: 1.5, y: 1.5)
        XCTAssertTrue(state.replacePage(PKDrawing(strokes: [modified]), at: 0))
        XCTAssertEqual(state.pageRevisions[0], 3)
        XCTAssertFalse(state.replacePage(state.drawing(at: 0), at: 0))
        XCTAssertTrue(state.replacePage(PKDrawing(strokes: [original]), at: 0), "Undo restores the original")
        XCTAssertTrue(state.replacePage(PKDrawing(strokes: [modified]), at: 0), "Redo restores the edit")
    }

    private func stroke(seed: UInt32, force: CGFloat, marker: Bool = false) -> PKStroke {
        let points = (0..<8).map { index in
            PKStrokePoint(
                location: CGPoint(x: CGFloat(index * 8), y: CGFloat(index * 4)),
                timeOffset: Double(index) / 60,
                size: CGSize(width: 3, height: 4),
                opacity: 0.8,
                force: force,
                azimuth: 0.7,
                altitude: 1.1
            )
        }
        var stroke = PKStroke(
            ink: PKInk(marker ? .marker : .pen, color: .black),
            path: PKStrokePath(controlPoints: points, creationDate: .distantPast),
            transform: CGAffineTransform(translationX: 20, y: 30),
            mask: UIBezierPath(rect: CGRect(x: 0, y: 0, width: 70, height: 60))
        )
        stroke.randomSeed = seed
        return stroke
    }
}
