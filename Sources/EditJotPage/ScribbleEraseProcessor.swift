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
            let coverage = (intersection.width * intersection.height)
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

/// Converts a completed freehand PencilKit stroke into a clean geometric stroke.
/// PencilKit exposes stroke construction publicly, but it doesn't expose the
/// automatic shape recognizer used by Apple's own apps. Keeping recognition in
/// this small, deterministic value type makes hold-to-snap work on iOS 16+
/// without relying on private PencilKit symbols.
struct PencilStrokeShapeSnapper {

    enum Shape: Equatable {
        case line
        case ellipse
        case rectangle
    }

    struct Result {
        let shape: Shape
        let stroke: PKStroke
    }

    private static let minimumDimension = CGFloat(24)

    static func snap(_ stroke: PKStroke) -> Result? {
        let sourcePoints = Array(stroke.path)
        guard sourcePoints.count >= 2 else { return nil }
        let locations = sourcePoints.map(\.location)

        if let line = lineLocations(from: locations) {
            return Result(
                shape: .line,
                stroke: makeStroke(from: stroke, sourcePoints: sourcePoints, locations: line)
            )
        }

        let bounds = locations.reduce(into: CGRect.null) { partial, point in
            partial = partial.union(CGRect(origin: point, size: .zero))
        }
        guard !bounds.isNull,
              bounds.width >= minimumDimension,
              bounds.height >= minimumDimension else { return nil }

        let diagonal = hypot(bounds.width, bounds.height)
        guard distance(locations[0], locations[locations.count - 1])
                <= max(18, diagonal * 0.2) else { return nil }

        if isRectangle(locations, bounds: bounds) {
            let rectangle = rectangleLocations(
                bounds: bounds,
                startingNear: locations[0],
                clockwise: signedArea(of: locations) >= 0
            )
            return Result(
                shape: .rectangle,
                stroke: makeStroke(
                    from: stroke,
                    sourcePoints: sourcePoints,
                    locations: rectangle
                )
            )
        }

        if isEllipse(locations, bounds: bounds) {
            let ellipse = ellipseLocations(
                bounds: bounds,
                startingNear: locations[0],
                clockwise: signedArea(of: locations) >= 0
            )
            return Result(
                shape: .ellipse,
                stroke: makeStroke(from: stroke, sourcePoints: sourcePoints, locations: ellipse)
            )
        }

        return nil
    }

    private static func lineLocations(from points: [CGPoint]) -> [CGPoint]? {
        guard let first = points.first, let last = points.last else { return nil }
        let chordLength = distance(first, last)
        guard chordLength >= minimumDimension else { return nil }

        var travelled = CGFloat.zero
        var maximumDeviation = CGFloat.zero
        for index in points.indices {
            if index > points.startIndex {
                travelled += distance(points[index - 1], points[index])
            }
            maximumDeviation = max(
                maximumDeviation,
                perpendicularDistance(points[index], lineStart: first, lineEnd: last)
            )
        }

        guard travelled / chordLength <= 1.16,
              maximumDeviation <= max(6, chordLength * 0.07) else { return nil }
        return (0..<6).map { index in
            let progress = CGFloat(index) / 5
            return CGPoint(
                x: first.x + (last.x - first.x) * progress,
                y: first.y + (last.y - first.y) * progress
            )
        }
    }

    private static func isRectangle(_ points: [CGPoint], bounds: CGRect) -> Bool {
        let scale = max(1, min(bounds.width, bounds.height))
        var totalError = CGFloat.zero
        var maximumError = CGFloat.zero
        var sideHits = Set<Int>()

        for point in points {
            let distances = [
                abs(point.y - bounds.minY),
                abs(point.x - bounds.maxX),
                abs(point.y - bounds.maxY),
                abs(point.x - bounds.minX),
            ]
            guard let minimum = distances.min(),
                  let side = distances.firstIndex(of: minimum) else { return false }
            let normalized = minimum / scale
            totalError += normalized
            maximumError = max(maximumError, normalized)
            if normalized <= 0.14 { sideHits.insert(side) }
        }

        let meanError = totalError / CGFloat(points.count)
        return meanError <= 0.075 && maximumError <= 0.24 && sideHits.count == 4
    }

    private static func isEllipse(_ points: [CGPoint], bounds: CGRect) -> Bool {
        let radiusX = bounds.width / 2
        let radiusY = bounds.height / 2
        guard radiusX > 0, radiusY > 0 else { return false }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        var totalError = CGFloat.zero
        var maximumError = CGFloat.zero
        var angles: [CGFloat] = []
        angles.reserveCapacity(points.count)
        for point in points {
            let x = (point.x - center.x) / radiusX
            let y = (point.y - center.y) / radiusY
            let error = abs(hypot(x, y) - 1)
            totalError += error
            maximumError = max(maximumError, error)
            angles.append(atan2(y, x))
        }

        var angularTravel = CGFloat.zero
        for index in 1..<angles.count {
            var delta = angles[index] - angles[index - 1]
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            angularTravel += abs(delta)
        }

        let meanError = totalError / CGFloat(points.count)
        return meanError <= 0.14 && maximumError <= 0.42 && angularTravel >= .pi * 1.6
    }

    private static func rectangleLocations(
        bounds: CGRect,
        startingNear start: CGPoint,
        clockwise: Bool
    ) -> [CGPoint] {
        let corners = [
            CGPoint(x: bounds.minX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.maxY),
            CGPoint(x: bounds.minX, y: bounds.maxY),
        ]
        let startIndex = corners.indices.min { distance(corners[$0], start) < distance(corners[$1], start) }
            ?? 0
        let direction = clockwise ? 1 : -1
        var locations: [CGPoint] = []
        for offset in 0...4 {
            let index = (startIndex + direction * offset + corners.count * 2) % corners.count
            locations.append(corners[index])
        }
        return locations
    }

    private static func ellipseLocations(
        bounds: CGRect,
        startingNear start: CGPoint,
        clockwise: Bool
    ) -> [CGPoint] {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radiusX = bounds.width / 2
        let radiusY = bounds.height / 2
        let startAngle = atan2(
            (start.y - center.y) / max(radiusY, 0.001),
            (start.x - center.x) / max(radiusX, 0.001)
        )
        let direction = clockwise ? CGFloat(1) : -1
        return (0...48).map { index in
            let angle = startAngle + direction * 2 * .pi * CGFloat(index) / 48
            return CGPoint(
                x: center.x + cos(angle) * radiusX,
                y: center.y + sin(angle) * radiusY
            )
        }
    }

    private static func makeStroke(
        from source: PKStroke,
        sourcePoints: [PKStrokePoint],
        locations: [CGPoint]
    ) -> PKStroke {
        let count = CGFloat(max(1, sourcePoints.count))
        let averageSize = sourcePoints.reduce(CGSize.zero) { partial, point in
            CGSize(width: partial.width + point.size.width, height: partial.height + point.size.height)
        }
        let size = CGSize(width: averageSize.width / count, height: averageSize.height / count)
        let opacity = sourcePoints.reduce(CGFloat.zero) { $0 + $1.opacity } / count
        let force = sourcePoints.reduce(CGFloat.zero) { $0 + $1.force } / count
        let azimuth = sourcePoints.reduce(CGFloat.zero) { $0 + $1.azimuth } / count
        let altitude = sourcePoints.reduce(CGFloat.zero) { $0 + $1.altitude } / count
        let duration = max(0.01, sourcePoints.last?.timeOffset ?? 0.01)
        let denominator = Double(max(1, locations.count - 1))
        let controlPoints = locations.enumerated().map { index, location in
            PKStrokePoint(
                location: location,
                timeOffset: duration * Double(index) / denominator,
                size: size,
                opacity: opacity,
                force: force,
                azimuth: azimuth,
                altitude: altitude
            )
        }
        return PKStroke(
            ink: source.ink,
            path: PKStrokePath(controlPoints: controlPoints, creationDate: source.path.creationDate),
            transform: source.transform,
            mask: source.mask
        )
    }

    private static func signedArea(of points: [CGPoint]) -> CGFloat {
        guard points.count > 2 else { return 0 }
        var area = CGFloat.zero
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            area += points[index].x * next.y - next.x * points[index].y
        }
        return area / 2
    }

    private static func perpendicularDistance(
        _ point: CGPoint,
        lineStart: CGPoint,
        lineEnd: CGPoint
    ) -> CGFloat {
        let dx = lineEnd.x - lineStart.x
        let dy = lineEnd.y - lineStart.y
        let length = hypot(dx, dy)
        guard length > 0 else { return distance(point, lineStart) }
        return abs(dy * point.x - dx * point.y + lineEnd.x * lineStart.y
            - lineEnd.y * lineStart.x) / length
    }

    private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}
