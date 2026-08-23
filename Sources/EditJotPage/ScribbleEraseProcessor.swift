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

import CoreGraphics
@preconcurrency import PencilKit

struct ScribbleEraseProcessor {

    static let coverageThreshold: CGFloat = 0.6
    static let minPasses: Int = 3

    // Minimum distance (in canvas points) the pen must travel in a direction
    // before it counts as a pass — filters out jitter and tiny wobbles.
    private static let minPassDistance: CGFloat = 15

    struct Result {
        let processedDrawing: PKDrawing
        let retainedPreviousStrokeIndices: [Int]
        let retainedAddedStrokes: [PKStroke]
    }

    private struct AddedStroke {
        let stroke: PKStroke
        let bounds: CGRect
        let isScribble: Bool
    }

    /// Inspects each newly added stroke for scribble motion (back-and-forth within a single
    /// pen-down gesture). A stroke qualifies as a scribble when its path changes primary-axis
    /// direction ≥ `minPasses` times with a travel distance of at least `minPassDistance` per
    /// segment. Qualifying scribble strokes that cover ≥ 60% of any existing stroke's
    /// renderBounds cause that existing stroke to be erased; the scribble stroke is also
    /// removed. Non-scribble strokes and scribbles that cover nothing are kept as-is.
    static func process(newDrawing: PKDrawing, previousDrawing: PKDrawing) -> Result? {
        let previousStrokes = previousDrawing.strokes
        let newStrokes = newDrawing.strokes

        guard newStrokes.count > previousStrokes.count, !previousStrokes.isEmpty else { return nil }

        let addedStrokes = newStrokes[previousStrokes.count...].map { stroke in
            AddedStroke(
                stroke: stroke,
                bounds: stroke.renderBounds,
                isScribble: countPasses(in: stroke) >= minPasses
            )
        }
        let scribbleBounds = addedStrokes.compactMap { $0.isScribble ? $0.bounds : nil }
        guard !scribbleBounds.isEmpty else { return nil }

        var indicesToErase = IndexSet()

        for (existingIndex, existingStroke) in previousStrokes.enumerated() {
            let existingBounds = existingStroke.renderBounds
            guard existingBounds.width > 0, existingBounds.height > 0 else { continue }

            var scribbleUnion = CGRect.null
            for bounds in scribbleBounds where bounds.intersects(existingBounds) {
                scribbleUnion = scribbleUnion.union(bounds)
            }
            guard !scribbleUnion.isNull else { continue }
            let intersection = existingBounds.intersection(scribbleUnion)
            let coverage =
                (intersection.width * intersection.height)
                / (existingBounds.width * existingBounds.height)

            if coverage >= coverageThreshold {
                indicesToErase.insert(existingIndex)
            }
        }

        guard !indicesToErase.isEmpty else { return nil }

        let erasedBounds = indicesToErase.map { previousStrokes[$0].renderBounds }

        var keptExistingStrokes: [PKStroke] = []
        var retainedPreviousStrokeIndices: [Int] = []
        keptExistingStrokes.reserveCapacity(previousStrokes.count - indicesToErase.count)
        retainedPreviousStrokeIndices.reserveCapacity(previousStrokes.count - indicesToErase.count)
        for (index, stroke) in previousStrokes.enumerated() where !indicesToErase.contains(index) {
            keptExistingStrokes.append(stroke)
            retainedPreviousStrokeIndices.append(index)
        }

        // Remove scribble strokes that overlapped an erased stroke; keep everything else.
        let keptAddedStrokes = addedStrokes.compactMap { added -> PKStroke? in
            guard added.isScribble else { return added.stroke }
            return erasedBounds.contains { added.bounds.intersects($0) } ? nil : added.stroke
        }

        return Result(
            processedDrawing: PKDrawing(strokes: keptExistingStrokes + keptAddedStrokes),
            retainedPreviousStrokeIndices: retainedPreviousStrokeIndices,
            retainedAddedStrokes: keptAddedStrokes
        )
    }

    // MARK: - Private

    /// Counts how many directional passes the stroke makes along its primary axis.
    /// One pass = travelling at least `minPassDistance` in a consistent direction.
    ///
    /// A smooth curve (circle, arc) travels roughly 2× the primary bounding dimension
    /// along that axis. A genuine zigzag travels N× where N equals the pass count.
    /// Strokes with a zigzag ratio below 2.5 are not considered scribbles.
    private static func countPasses(in stroke: PKStroke) -> Int {
        let path = stroke.path
        guard path.count >= 5 else { return 1 }

        let bounds = stroke.renderBounds
        let useXAxis = bounds.width >= bounds.height
        let primaryDimension = useXAxis ? bounds.width : bounds.height
        guard primaryDimension > 0 else { return 1 }

        var passes = 1
        var currentDirection: CGFloat = 0
        var accumulated: CGFloat = 0
        var totalTravel: CGFloat = 0

        for index in 1..<path.count {
            let delta =
                useXAxis
                ? path[index].location.x - path[index - 1].location.x
                : path[index].location.y - path[index - 1].location.y

            guard abs(delta) > 0.5 else { continue }
            totalTravel += abs(delta)

            let direction: CGFloat = delta > 0 ? 1 : -1

            if currentDirection == 0 {
                currentDirection = direction
                accumulated = abs(delta)
            } else if direction == currentDirection {
                accumulated += abs(delta)
            } else if accumulated >= minPassDistance {
                passes += 1
                currentDirection = direction
                accumulated = abs(delta)
            }
        }

        // Smooth curves travel ≈2× the primary dimension (circle: exactly 2×).
        // Genuine zigzags travel ≈passes× the primary dimension.
        // Require ratio ≥ 2.5 to exclude all smooth curves regardless of shape.
        let zigzagRatio = totalTravel / primaryDimension
        guard zigzagRatio >= 2.5 else { return 1 }

        return passes
    }
}
