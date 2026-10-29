@preconcurrency import PencilKit
import QuartzCore
import XCTest

@testable import Jottre

@MainActor
final class EditorInkPerformanceTests: XCTestCase {
    /// Repeatable CPU microbenchmark; not a substitute for Pencil latency on hardware.
    func testPageCommitScaling() {
        for count in [0, 100, 500, 1_000] {
            let strokes = (0..<count).map { makeStroke($0) }
            let indices = (0..<count).map { $0 % 10 }
            let state = JotEditorDrawingState()
            state.load(drawing: PKDrawing(strokes: strokes), strokePageIndices: indices)
            let page = strokes.enumerated().compactMap { $0.offset % 10 == 0 ? $0.element : nil }
            let a = PKDrawing(strokes: page + [makeStroke(count + 1)])
            let b = PKDrawing(strokes: page + [makeStroke(count + 2)])
            let start = CACurrentMediaTime()
            for iteration in 0..<30 {
                XCTAssertTrue(state.replacePage(iteration.isMultiple(of: 2) ? a : b, at: 0))
            }
            let milliseconds = (CACurrentMediaTime() - start) * 1_000 / 30
            print("[InkBenchmark] strokes=\(count), pages=10, pageReplacementMeanMs=\(milliseconds)")
            XCTAssertEqual(state.committedDrawing.strokes.count, count + 1)
        }
    }

    private func makeStroke(_ index: Int) -> PKStroke {
        let points: [PKStrokePoint] = (0..<64).map { sample in
            let location = CGPoint(x: CGFloat(sample * 2), y: CGFloat(index * 3 + sample % 9))
            return PKStrokePoint(
                location: location,
                timeOffset: Double(sample) / 120,
                size: CGSize(width: 3, height: 3),
                opacity: 1,
                force: CGFloat(sample + 1) / 64,
                azimuth: 0.3,
                altitude: 1.2
            )
        }
        return PKStroke(
            ink: PKInk(.pen, color: .black),
            path: PKStrokePath(controlPoints: points, creationDate: .distantPast)
        )
    }
}
