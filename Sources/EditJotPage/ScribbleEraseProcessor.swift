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

@preconcurrency import PencilKit
import CoreGraphics

struct ScribbleEraseProcessor {

    static let coverageThreshold: CGFloat = 0.6
    static let minPasses: Int = 3

    // Minimum distance (in canvas points) the pen must travel in a direction
    // before it counts as a pass — filters out jitter and tiny wobbles.
    private static let minPassDistance: CGFloat = 15

    struct Result {
        let processedDrawing: PKDrawing
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

        let addedStrokes = Array(newStrokes[previousStrokes.count...])
        let scribbleStrokes = addedStrokes.filter { countPasses(in: $0) >= minPasses }
        guard !scribbleStrokes.isEmpty else { return nil }

        var indicesToErase = IndexSet()

        for (existingIndex, existingStroke) in previousStrokes.enumerated() {
            let existingBounds = existingStroke.renderBounds
            guard existingBounds.width > 0, existingBounds.height > 0 else { continue }

            let overlapping = scribbleStrokes.filter { $0.renderBounds.intersects(existingBounds) }
            guard !overlapping.isEmpty else { continue }

            let scribbleUnion = overlapping.map { $0.renderBounds }.reduce(CGRect.null) { $0.union($1) }
            let intersection = existingBounds.intersection(scribbleUnion)
            let coverage = (intersection.width * intersection.height)
                / (existingBounds.width * existingBounds.height)

            if coverage >= coverageThreshold {
                indicesToErase.insert(existingIndex)
            }
        }

        guard !indicesToErase.isEmpty else { return nil }

        let erasedBounds = indicesToErase.map { previousStrokes[$0].renderBounds }

        let keptExistingStrokes = previousStrokes
            .enumerated()
            .compactMap { indicesToErase.contains($0.offset) ? nil : $0.element }

        // Remove scribble strokes that overlapped an erased stroke; keep everything else.
        let keptAddedStrokes = addedStrokes.filter { stroke in
            let isScribble = countPasses(in: stroke) >= minPasses
            guard isScribble else { return true }
            return !erasedBounds.contains { stroke.renderBounds.intersects($0) }
        }

        return Result(processedDrawing: PKDrawing(strokes: keptExistingStrokes + keptAddedStrokes))
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
            let delta = useXAxis
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
