/*
 Jottre: Minimalistic jotting for iPhone, iPad and Mac.
 Copyright (C) 2021-2026 Anton Lorani

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

import Foundation
@preconcurrency import PencilKit
import UIKit
import XCTest

@testable import Jottre

final class JotDrawingLayerPartitionTests: XCTestCase {

    func testStablePartitionKeepsPageMetadataAligned() {
        let pen = makeStroke(type: .pen, seed: 11)
        let firstMarker = makeStroke(type: .marker, seed: 22)
        let pencil = makeStroke(type: .pencil, seed: 33)
        let secondMarker = makeStroke(type: .marker, seed: 44)

        let layers = JotDrawingLayerPartition(
            drawing: PKDrawing(strokes: [pen, firstMarker, pencil, secondMarker]),
            strokePageIndices: [1, 2, 3, 4]
        )

        XCTAssertEqual(layers.highlighter.strokes.map(\.randomSeed), [22, 44])
        XCTAssertEqual(layers.foreground.strokes.map(\.randomSeed), [11, 33])
        XCTAssertEqual(layers.highlighterPageIndices, [2, 4])
        XCTAssertEqual(layers.foregroundPageIndices, [1, 3])
        XCTAssertEqual(layers.combined.strokes.map(\.randomSeed), [22, 44, 11, 33])
        XCTAssertEqual(layers.combinedPageIndices, [2, 4, 1, 3])
    }

    func testCombinedDrawingRoundTripsWithoutChangingJotSchema() throws {
        let source = PKDrawing(strokes: [
            makeStroke(type: .pen, seed: 10),
            makeStroke(type: .marker, seed: 20),
        ])
        let combined = JotDrawingLayerPartition(drawing: source).combined

        let decoded = try PKDrawing(data: combined.dataRepresentation())

        XCTAssertEqual(decoded.strokes.map(\.ink.inkType), [.marker, .pen])
        XCTAssertEqual(decoded.strokes.map(\.randomSeed), [20, 10])
    }

    private func makeStroke(type: PKInk.InkType, seed: UInt32) -> PKStroke {
        let points = [
            PKStrokePoint(
                location: CGPoint(x: CGFloat(seed), y: 10),
                timeOffset: 0,
                size: CGSize(width: 5, height: 5),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            ),
            PKStrokePoint(
                location: CGPoint(x: CGFloat(seed) + 20, y: 30),
                timeOffset: 0.1,
                size: CGSize(width: 5, height: 5),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            ),
        ]
        return PKStroke(
            ink: PKInk(type, color: .systemBlue),
            path: PKStrokePath(
                controlPoints: points,
                creationDate: Date(timeIntervalSinceReferenceDate: 1_000)
            ),
            transform: .identity,
            mask: nil,
            randomSeed: seed
        )
    }
}
