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
import Foundation
@preconcurrency import PencilKit

/// Recognizes a completed freehand stroke and replaces its centerline with a
/// deterministic geometric fit. PencilKit does not expose the shape recognizer
/// used by Apple's apps, but it does expose all of the stroke construction APIs
/// needed to build a native, serializable replacement.
struct PencilStrokeShapeSnapper {

    enum Shape: Equatable, Sendable {
        case line
        case circle
        case ellipse
        case rectangle
        case triangle
        case arrow
    }

    struct Result: Sendable {
        let shape: Shape
        let stroke: PKStroke
    }

    fileprivate struct LineFit {
        let center: CGPoint
        let direction: CGVector
    }

    fileprivate struct PolygonError {
        let mean: CGFloat
        let rootMeanSquare: CGFloat
        let maximum: CGFloat
    }

    fileprivate struct EllipseFit {
        let center: CGPoint
        let axisX: CGVector
        let axisY: CGVector
        let radiusX: CGFloat
        let radiusY: CGFloat
        let signedAngularTravel: CGFloat
    }

    private static let minimumLineLength = CGFloat(24)
    private static let minimumClosedShapeDiagonal = CGFloat(30)
    private static let maximumSampleCount = 160

    static func snap(_ stroke: PKStroke) -> Result? {
        let sourcePoints = Array(stroke.path)
        guard sourcePoints.count >= 2 else { return nil }

        let samples = uniformlySampledLocations(from: stroke.path)
        guard samples.count >= 2 else { return nil }

        if let locations = fittedLineLocations(from: samples) {
            return result(.line, source: stroke, sourcePoints: sourcePoints, locations: locations)
        }

        if let locations = fittedArrowLocations(from: samples) {
            return result(.arrow, source: stroke, sourcePoints: sourcePoints, locations: locations)
        }

        let bounds = boundingRect(of: samples)
        let diagonal = hypot(bounds.width, bounds.height)
        let travelled = polylineLength(samples)
        guard diagonal >= minimumClosedShapeDiagonal,
            travelled >= diagonal * 1.75,
            let first = samples.first,
            let last = samples.last,
            distance(first, last) <= max(7, diagonal * 0.13)
        else { return nil }

        if let vertices = fittedRectangleVertices(from: samples, diagonal: diagonal) {
            return result(
                .rectangle,
                source: stroke,
                sourcePoints: sourcePoints,
                locations: sharpPolyline(vertices: vertices, closed: true)
            )
        }

        if let vertices = fittedTriangleVertices(from: samples, diagonal: diagonal) {
            return result(
                .triangle,
                source: stroke,
                sourcePoints: sourcePoints,
                locations: sharpPolyline(vertices: vertices, closed: true)
            )
        }

        if let ellipse = fittedEllipse(from: samples) {
            let ratio =
                max(ellipse.radiusX, ellipse.radiusY)
                / max(0.001, min(ellipse.radiusX, ellipse.radiusY))
            let shape: Shape
            let radiusX: CGFloat
            let radiusY: CGFloat
            if ratio <= 1.15 {
                shape = .circle
                radiusX = (ellipse.radiusX + ellipse.radiusY) / 2
                radiusY = radiusX
            } else {
                shape = .ellipse
                radiusX = ellipse.radiusX
                radiusY = ellipse.radiusY
            }
            let locations = ellipseLocations(
                center: ellipse.center,
                axisX: ellipse.axisX,
                axisY: ellipse.axisY,
                radiusX: radiusX,
                radiusY: radiusY,
                startingNear: samples[0],
                direction: ellipse.signedAngularTravel >= 0 ? 1 : -1
            )
            return result(shape, source: stroke, sourcePoints: sourcePoints, locations: locations)
        }

        return nil
    }
}

// MARK: - Recognition

extension PencilStrokeShapeSnapper {

    fileprivate static func fittedLineLocations(from points: [CGPoint]) -> [CGPoint]? {
        guard let first = points.first,
            let last = points.last,
            let fit = leastSquaresLine(for: points)
        else { return nil }
        var direction = fit.direction
        if dot(vector(from: fit.center, to: last), direction)
            < dot(vector(from: fit.center, to: first), direction)
        {
            direction = -direction
        }

        let projections = points.map { dot(vector(from: fit.center, to: $0), direction) }
        guard let minimum = projections.min(), let maximum = projections.max() else { return nil }
        let length = maximum - minimum
        guard length >= minimumLineLength else { return nil }

        let residuals = points.map {
            abs(cross(vector(from: fit.center, to: $0), direction))
        }
        let rootMeanSquare = sqrt(
            residuals.reduce(CGFloat.zero) { $0 + $1 * $1 }
                / CGFloat(residuals.count)
        )
        let maximumResidual = residuals.max() ?? .infinity
        let travelled = polylineLength(points)
        guard travelled / length <= 1.22,
            rootMeanSquare <= max(2.5, length * 0.04),
            maximumResidual <= max(6, length * 0.11)
        else { return nil }

        let start = fit.center + direction * minimum
        let end = fit.center + direction * maximum
        return evenlySpacedLine(from: start, to: end, count: 8)
    }

    fileprivate static func fittedRectangleVertices(from points: [CGPoint], diagonal: CGFloat) -> [CGPoint]? {
        guard let rough = polygonCandidate(vertexCount: 4, from: points, diagonal: diagonal),
            isRectangleLike(rough)
        else { return nil }

        let longestEdgeIndex =
            rough.indices.max { lhs, rhs in
                distance(rough[lhs], rough[(lhs + 1) % rough.count])
                    < distance(rough[rhs], rough[(rhs + 1) % rough.count])
            } ?? 0
        guard
            let axisX = normalized(
                vector(
                    from: rough[longestEdgeIndex],
                    to: rough[(longestEdgeIndex + 1) % rough.count]
                )
            )
        else { return nil }
        let axisY = CGVector(dx: -axisX.dy, dy: axisX.dx)

        let xValues = points.map { dot(vector(from: .zero, to: $0), axisX) }
        let yValues = points.map { dot(vector(from: .zero, to: $0), axisY) }
        guard let minX = xValues.min(), let maxX = xValues.max(),
            let minY = yValues.min(), let maxY = yValues.max(),
            maxX - minX >= max(16, diagonal * 0.14),
            maxY - minY >= max(16, diagonal * 0.14)
        else { return nil }

        let corners = [
            point(axisX: axisX, x: minX, axisY: axisY, y: minY),
            point(axisX: axisX, x: maxX, axisY: axisY, y: minY),
            point(axisX: axisX, x: maxX, axisY: axisY, y: maxY),
            point(axisX: axisX, x: minX, axisY: axisY, y: maxY),
        ]
        let ordered = orderedPolygon(corners, matching: points)
        let error = polygonError(points: points, vertices: ordered)
        guard error.mean <= diagonal * 0.032,
            error.rootMeanSquare <= diagonal * 0.045,
            error.maximum <= diagonal * 0.12
        else { return nil }
        return ordered
    }

    fileprivate static func fittedTriangleVertices(from points: [CGPoint], diagonal: CGFloat) -> [CGPoint]? {
        guard let rough = polygonCandidate(vertexCount: 3, from: points, diagonal: diagonal),
            isTriangleLike(rough, diagonal: diagonal)
        else { return nil }
        let refined = refinedPolygon(rough, using: points) ?? rough
        let ordered = orderedPolygon(refined, matching: points)
        guard isTriangleLike(ordered, diagonal: diagonal) else { return nil }

        let error = polygonError(points: points, vertices: ordered)
        guard error.mean <= diagonal * 0.035,
            error.rootMeanSquare <= diagonal * 0.05,
            error.maximum <= diagonal * 0.13
        else { return nil }
        return ordered
    }

    fileprivate static func fittedEllipse(from points: [CGPoint]) -> EllipseFit? {
        let mean = centroid(of: points)
        var xx = CGFloat.zero
        var xy = CGFloat.zero
        var yy = CGFloat.zero
        for point in points {
            let dx = point.x - mean.x
            let dy = point.y - mean.y
            xx += dx * dx
            xy += dx * dy
            yy += dy * dy
        }
        let angle = 0.5 * atan2(2 * xy, xx - yy)
        let axisX = CGVector(dx: cos(angle), dy: sin(angle))
        let axisY = CGVector(dx: -sin(angle), dy: cos(angle))
        let xValues = points.map { dot(vector(from: mean, to: $0), axisX) }
        let yValues = points.map { dot(vector(from: mean, to: $0), axisY) }
        guard let minX = xValues.min(), let maxX = xValues.max(),
            let minY = yValues.min(), let maxY = yValues.max()
        else { return nil }

        let radiusX = (maxX - minX) / 2
        let radiusY = (maxY - minY) / 2
        guard min(radiusX, radiusY) >= 10,
            max(radiusX, radiusY) / min(radiusX, radiusY) <= 8
        else { return nil }

        let center = mean + axisX * ((minX + maxX) / 2) + axisY * ((minY + maxY) / 2)
        var radialErrors: [CGFloat] = []
        var angles: [CGFloat] = []
        radialErrors.reserveCapacity(points.count)
        angles.reserveCapacity(points.count)
        for point in points {
            let offset = vector(from: center, to: point)
            let x = dot(offset, axisX) / radiusX
            let y = dot(offset, axisY) / radiusY
            radialErrors.append(abs(hypot(x, y) - 1))
            angles.append(atan2(y, x))
        }

        var signedTravel = CGFloat.zero
        var absoluteTravel = CGFloat.zero
        for index in 1..<angles.count {
            var delta = angles[index] - angles[index - 1]
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            signedTravel += delta
            absoluteTravel += abs(delta)
        }

        let meanError = radialErrors.reduce(0, +) / CGFloat(radialErrors.count)
        let maximumError = radialErrors.max() ?? .infinity
        guard meanError <= 0.11,
            maximumError <= 0.32,
            abs(signedTravel) >= .pi * 1.55,
            absoluteTravel <= abs(signedTravel) * 1.35 + 0.25
        else { return nil }

        return EllipseFit(
            center: center,
            axisX: axisX,
            axisY: axisY,
            radiusX: radiusX,
            radiusY: radiusY,
            signedAngularTravel: signedTravel
        )
    }

    fileprivate static func fittedArrowLocations(from points: [CGPoint]) -> [CGPoint]? {
        if let locations = canonicalArrowLocations(from: points) { return locations }
        return canonicalArrowLocations(from: points.reversed())
    }

    fileprivate static func canonicalArrowLocations<S: Collection>(from source: S) -> [CGPoint]?
    where S.Element == CGPoint {
        let points = Array(source)
        let diagonal = hypot(boundingRect(of: points).width, boundingRect(of: points).height)
        guard diagonal >= minimumLineLength else { return nil }

        for toleranceRatio in [0.012, 0.018, 0.026, 0.038, 0.055] as [CGFloat] {
            let simplified = simplifyOpen(points, tolerance: diagonal * toleranceRatio)
            guard simplified.count == 5 else { continue }

            let tail = simplified[0]
            let firstTip = simplified[1]
            let firstWing = simplified[2]
            let secondTip = simplified[3]
            let secondWing = simplified[4]
            let tip = midpoint(firstTip, secondTip)
            let shaftLength = distance(tail, tip)
            guard shaftLength >= minimumLineLength,
                distance(firstTip, secondTip) <= max(8, shaftLength * 0.14)
            else { continue }

            let firstHeadLength = distance(tip, firstWing)
            let secondHeadLength = distance(tip, secondWing)
            guard firstHeadLength >= shaftLength * 0.12,
                secondHeadLength >= shaftLength * 0.12,
                firstHeadLength <= shaftLength * 0.58,
                secondHeadLength <= shaftLength * 0.58,
                max(firstHeadLength, secondHeadLength)
                    / max(0.001, min(firstHeadLength, secondHeadLength)) <= 1.9,
                let backDirection = normalized(vector(from: tip, to: tail)),
                let firstDirection = normalized(vector(from: tip, to: firstWing)),
                let secondDirection = normalized(vector(from: tip, to: secondWing))
            else { continue }

            let firstAngle = acos(clamp(dot(backDirection, firstDirection), minimum: -1, maximum: 1))
            let secondAngle = acos(clamp(dot(backDirection, secondDirection), minimum: -1, maximum: 1))
            guard firstAngle >= .pi / 12,
                secondAngle >= .pi / 12,
                firstAngle <= .pi * 0.44,
                secondAngle <= .pi * 0.44,
                cross(backDirection, firstDirection) * cross(backDirection, secondDirection) < 0
            else { continue }

            let headLength = (firstHeadLength + secondHeadLength) / 2
            let headAngle = (firstAngle + secondAngle) / 2
            let firstSide: CGFloat = cross(backDirection, firstDirection) >= 0 ? 1 : -1
            let fittedFirstWing = tip + rotated(backDirection, by: firstSide * headAngle) * headLength
            let fittedSecondWing = tip + rotated(backDirection, by: -firstSide * headAngle) * headLength
            return sharpPolyline(
                vertices: [tail, tip, fittedFirstWing, tip, fittedSecondWing],
                closed: false
            )
        }
        return nil
    }
}

// MARK: - Polygon fitting

extension PencilStrokeShapeSnapper {

    fileprivate static func polygonCandidate(
        vertexCount: Int,
        from points: [CGPoint],
        diagonal: CGFloat
    ) -> [CGPoint]? {
        var best: (vertices: [CGPoint], error: CGFloat)?
        for ratio in [0.012, 0.018, 0.026, 0.038, 0.052, 0.072, 0.10, 0.14] as [CGFloat] {
            let vertices = simplifyClosed(points, tolerance: diagonal * ratio)
            guard vertices.count == vertexCount, isConvex(vertices) else { continue }
            let error = polygonError(points: points, vertices: vertices).rootMeanSquare
            if error < best?.error ?? .infinity {
                best = (vertices, error)
            }
        }
        return best?.vertices
    }

    fileprivate static func isRectangleLike(_ vertices: [CGPoint]) -> Bool {
        guard vertices.count == 4, isConvex(vertices) else { return false }
        var edgeDirections: [CGVector] = []
        var edgeLengths: [CGFloat] = []
        for index in vertices.indices {
            let edge = vector(from: vertices[index], to: vertices[(index + 1) % vertices.count])
            let length = magnitude(edge)
            guard length > 0, let direction = normalized(edge) else { return false }
            edgeDirections.append(direction)
            edgeLengths.append(length)
        }

        for index in vertices.indices {
            let next = (index + 1) % vertices.count
            guard abs(dot(edgeDirections[index], edgeDirections[next])) <= 0.42 else { return false }
        }
        guard abs(cross(edgeDirections[0], edgeDirections[2])) <= 0.25,
            abs(cross(edgeDirections[1], edgeDirections[3])) <= 0.25,
            max(edgeLengths[0], edgeLengths[2]) / min(edgeLengths[0], edgeLengths[2]) <= 1.55,
            max(edgeLengths[1], edgeLengths[3]) / min(edgeLengths[1], edgeLengths[3]) <= 1.55
        else { return false }
        return true
    }

    fileprivate static func isTriangleLike(_ vertices: [CGPoint], diagonal: CGFloat) -> Bool {
        guard vertices.count == 3, isConvex(vertices),
            abs(signedArea(of: vertices)) >= diagonal * diagonal * 0.045
        else { return false }
        for index in vertices.indices {
            let previous = vertices[(index + vertices.count - 1) % vertices.count]
            let current = vertices[index]
            let next = vertices[(index + 1) % vertices.count]
            guard distance(current, previous) >= diagonal * 0.16,
                distance(current, next) >= diagonal * 0.16,
                let first = normalized(vector(from: current, to: previous)),
                let second = normalized(vector(from: current, to: next))
            else { return false }
            let angle = acos(clamp(dot(first, second), minimum: -1, maximum: 1))
            guard angle >= .pi / 10, angle <= .pi * 0.84 else { return false }
        }
        return true
    }

    fileprivate static func refinedPolygon(_ vertices: [CGPoint], using points: [CGPoint]) -> [CGPoint]? {
        var pointGroups = Array(repeating: [CGPoint](), count: vertices.count)
        for point in points {
            let edgeIndex =
                vertices.indices.min { lhs, rhs in
                    distanceToSegment(point, vertices[lhs], vertices[(lhs + 1) % vertices.count])
                        < distanceToSegment(point, vertices[rhs], vertices[(rhs + 1) % vertices.count])
                } ?? 0
            pointGroups[edgeIndex].append(point)
        }
        let lines = pointGroups.enumerated().map { index, group -> LineFit? in
            guard group.count >= 2 else {
                return lineThrough(vertices[index], vertices[(index + 1) % vertices.count])
            }
            return leastSquaresLine(for: group)
        }
        let resolvedLines = lines.compactMap { $0 }
        guard resolvedLines.count == vertices.count else { return nil }

        let intersections = vertices.indices.compactMap { index in
            let previous = resolvedLines[(index + vertices.count - 1) % vertices.count]
            let current = resolvedLines[index]
            return intersection(previous, current)
        }
        return intersections.count == vertices.count ? intersections : nil
    }

    fileprivate static func polygonError(points: [CGPoint], vertices: [CGPoint]) -> PolygonError {
        let distances = points.map { point in
            vertices.indices.map { index in
                distanceToSegment(point, vertices[index], vertices[(index + 1) % vertices.count])
            }.min() ?? .infinity
        }
        let count = CGFloat(max(1, distances.count))
        return PolygonError(
            mean: distances.reduce(0, +) / count,
            rootMeanSquare: sqrt(distances.reduce(0) { $0 + $1 * $1 } / count),
            maximum: distances.max() ?? .infinity
        )
    }

    fileprivate static func orderedPolygon(_ vertices: [CGPoint], matching points: [CGPoint]) -> [CGPoint] {
        guard let start = points.first, !vertices.isEmpty else { return vertices }
        var result = vertices
        if (signedArea(of: result) >= 0) != (signedArea(of: points) >= 0) {
            result.reverse()
        }
        let startIndex =
            result.indices.min {
                distance(result[$0], start) < distance(result[$1], start)
            } ?? 0
        return Array(result[startIndex...] + result[..<startIndex])
    }

    fileprivate static func isConvex(_ vertices: [CGPoint]) -> Bool {
        guard vertices.count >= 3 else { return false }
        var sign = CGFloat.zero
        for index in vertices.indices {
            let first = vector(from: vertices[index], to: vertices[(index + 1) % vertices.count])
            let second = vector(
                from: vertices[(index + 1) % vertices.count],
                to: vertices[(index + 2) % vertices.count]
            )
            let value = cross(first, second)
            guard abs(value) > 0.001 else { continue }
            if sign == 0 {
                sign = value > 0 ? 1 : -1
            } else if value * sign < 0 {
                return false
            }
        }
        return sign != 0
    }
}

// MARK: - Sampling and simplification

extension PencilStrokeShapeSnapper {

    fileprivate static func uniformlySampledLocations(from path: PKStrokePath) -> [CGPoint] {
        guard path.count >= 2 else { return Array(path).map(\.location) }
        let upperBound = CGFloat(path.count - 1)
        let step = max(0.04, upperBound / 256)
        var dense = Array(
            path.interpolatedPoints(in: 0...upperBound, by: .parametricStep(step))
        ).map(\.location)
        if let first = path.first?.location, dense.first.map({ distance($0, first) > 0.01 }) != false {
            dense.insert(first, at: 0)
        }
        if let last = path.last?.location, dense.last.map({ distance($0, last) > 0.01 }) != false {
            dense.append(last)
        }
        dense = removingAdjacentDuplicates(from: dense, tolerance: 0.15)
        let length = polylineLength(dense)
        let count = min(maximumSampleCount, max(32, Int(ceil(length / 4))))
        return uniformlyResampled(dense, count: count)
    }

    fileprivate static func uniformlyResampled(_ points: [CGPoint], count: Int) -> [CGPoint] {
        guard points.count >= 2, count >= 2 else { return points }
        var cumulative = [CGFloat.zero]
        cumulative.reserveCapacity(points.count)
        for index in 1..<points.count {
            cumulative.append(cumulative[index - 1] + distance(points[index - 1], points[index]))
        }
        guard let total = cumulative.last, total > 0 else { return [points[0]] }

        var result: [CGPoint] = []
        result.reserveCapacity(count)
        var segment = 1
        for index in 0..<count {
            let target = total * CGFloat(index) / CGFloat(count - 1)
            while segment < cumulative.count - 1, cumulative[segment] < target {
                segment += 1
            }
            let startDistance = cumulative[segment - 1]
            let segmentLength = cumulative[segment] - startDistance
            let progress = segmentLength > 0 ? (target - startDistance) / segmentLength : 0
            result.append(interpolate(points[segment - 1], points[segment], progress: progress))
        }
        return result
    }

    fileprivate static func simplifyOpen(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var maximumDistance = CGFloat.zero
        var splitIndex = 0
        for index in 1..<(points.count - 1) {
            let candidate = distanceToSegment(points[index], points[0], points[points.count - 1])
            if candidate > maximumDistance {
                maximumDistance = candidate
                splitIndex = index
            }
        }
        guard maximumDistance > tolerance else { return [points[0], points[points.count - 1]] }
        let first = simplifyOpen(Array(points[...splitIndex]), tolerance: tolerance)
        let second = simplifyOpen(Array(points[splitIndex...]), tolerance: tolerance)
        return Array(first.dropLast()) + second
    }

    fileprivate static func simplifyClosed(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        var ring = removingAdjacentDuplicates(from: points, tolerance: 0.5)
        if ring.count > 1, distance(ring[0], ring[ring.count - 1]) <= tolerance * 2 {
            ring.removeLast()
        }
        guard ring.count >= 3 else { return ring }

        var firstIndex = 0
        var secondIndex = 1
        var maximumDistance = CGFloat.zero
        for lhs in ring.indices {
            for rhs in (lhs + 1)..<ring.count {
                let candidate = squaredDistance(ring[lhs], ring[rhs])
                if candidate > maximumDistance {
                    maximumDistance = candidate
                    firstIndex = lhs
                    secondIndex = rhs
                }
            }
        }
        let firstPath = Array(ring[firstIndex...secondIndex])
        let secondPath = Array(ring[secondIndex...] + ring[..<firstIndex]) + [ring[firstIndex]]
        let firstSimplified = simplifyOpen(firstPath, tolerance: tolerance)
        let secondSimplified = simplifyOpen(secondPath, tolerance: tolerance)
        return removingAdjacentDuplicates(
            from: Array(firstSimplified.dropLast()) + Array(secondSimplified.dropLast()),
            tolerance: tolerance * 0.25
        )
    }

    fileprivate static func removingAdjacentDuplicates(from points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        var result: [CGPoint] = []
        result.reserveCapacity(points.count)
        for point in points where result.last.map({ distance($0, point) > tolerance }) != false {
            result.append(point)
        }
        return result
    }
}

// MARK: - Stroke construction

extension PencilStrokeShapeSnapper {

    fileprivate static func result(
        _ shape: Shape,
        source: PKStroke,
        sourcePoints: [PKStrokePoint],
        locations: [CGPoint]
    ) -> Result {
        Result(
            shape: shape,
            stroke: makeStroke(from: source, sourcePoints: sourcePoints, locations: locations)
        )
    }

    fileprivate static func makeStroke(
        from source: PKStroke,
        sourcePoints: [PKStrokePoint],
        locations: [CGPoint]
    ) -> PKStroke {
        let count = CGFloat(max(1, sourcePoints.count))
        let summedSize = sourcePoints.reduce(CGSize.zero) { partial, point in
            CGSize(width: partial.width + point.size.width, height: partial.height + point.size.height)
        }
        let size = CGSize(width: summedSize.width / count, height: summedSize.height / count)
        let opacity = sourcePoints.reduce(CGFloat.zero) { $0 + $1.opacity } / count
        let force = sourcePoints.reduce(CGFloat.zero) { $0 + $1.force } / count
        let altitude = sourcePoints.reduce(CGFloat.zero) { $0 + $1.altitude } / count
        let azimuth = atan2(
            sourcePoints.reduce(CGFloat.zero) { $0 + sin($1.azimuth) },
            sourcePoints.reduce(CGFloat.zero) { $0 + cos($1.azimuth) }
        )
        let duration = max(0.01, sourcePoints.map(\.timeOffset).max() ?? 0.01)
        let denominator = Double(max(1, locations.count - 1))

        let controlPoints = locations.enumerated().map { index, location in
            let timeOffset = duration * Double(index) / denominator
            if #available(iOS 26.0, macOS 26.0, macCatalyst 26.0, *) {
                let secondaryScale = sourcePoints.reduce(CGFloat.zero) { $0 + $1.secondaryScale } / count
                let threshold = sourcePoints.reduce(CGFloat.zero) { $0 + $1.threshold } / count
                return PKStrokePoint(
                    location: location,
                    timeOffset: timeOffset,
                    size: size,
                    opacity: opacity,
                    force: force,
                    azimuth: azimuth,
                    altitude: altitude,
                    secondaryScale: secondaryScale,
                    threshold: threshold
                )
            } else if #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *) {
                let secondaryScale = sourcePoints.reduce(CGFloat.zero) { $0 + $1.secondaryScale } / count
                return PKStrokePoint(
                    location: location,
                    timeOffset: timeOffset,
                    size: size,
                    opacity: opacity,
                    force: force,
                    azimuth: azimuth,
                    altitude: altitude,
                    secondaryScale: secondaryScale
                )
            } else {
                return PKStrokePoint(
                    location: location,
                    timeOffset: timeOffset,
                    size: size,
                    opacity: opacity,
                    force: force,
                    azimuth: azimuth,
                    altitude: altitude
                )
            }
        }
        return PKStroke(
            ink: source.ink,
            path: PKStrokePath(controlPoints: controlPoints, creationDate: source.path.creationDate),
            transform: source.transform,
            mask: nil,
            randomSeed: source.randomSeed
        )
    }

    fileprivate static func sharpPolyline(vertices: [CGPoint], closed: Bool) -> [CGPoint] {
        guard let first = vertices.first else { return [] }
        var locations: [CGPoint] = []
        locations.reserveCapacity((vertices.count + (closed ? 1 : 0)) * 3)
        for vertex in vertices {
            locations.append(contentsOf: repeatElement(vertex, count: 3))
        }
        if closed {
            locations.append(contentsOf: repeatElement(first, count: 3))
        }
        return locations
    }

    fileprivate static func ellipseLocations(
        center: CGPoint,
        axisX: CGVector,
        axisY: CGVector,
        radiusX: CGFloat,
        radiusY: CGFloat,
        startingNear start: CGPoint,
        direction: CGFloat
    ) -> [CGPoint] {
        let offset = vector(from: center, to: start)
        let startAngle = atan2(dot(offset, axisY) / radiusY, dot(offset, axisX) / radiusX)
        return (0...72).map { index in
            let angle = startAngle + direction * 2 * .pi * CGFloat(index) / 72
            return center + axisX * (cos(angle) * radiusX) + axisY * (sin(angle) * radiusY)
        }
    }

    fileprivate static func evenlySpacedLine(from start: CGPoint, to end: CGPoint, count: Int) -> [CGPoint] {
        (0..<count).map { index in
            interpolate(start, end, progress: CGFloat(index) / CGFloat(max(1, count - 1)))
        }
    }
}

// MARK: - Geometry

extension PencilStrokeShapeSnapper {

    fileprivate static func leastSquaresLine(for points: [CGPoint]) -> LineFit? {
        guard points.count >= 2 else { return nil }
        let center = centroid(of: points)
        var xx = CGFloat.zero
        var xy = CGFloat.zero
        var yy = CGFloat.zero
        for point in points {
            let dx = point.x - center.x
            let dy = point.y - center.y
            xx += dx * dx
            xy += dx * dy
            yy += dy * dy
        }
        guard xx + yy > 0 else { return nil }
        let angle = 0.5 * atan2(2 * xy, xx - yy)
        return LineFit(center: center, direction: CGVector(dx: cos(angle), dy: sin(angle)))
    }

    fileprivate static func lineThrough(_ start: CGPoint, _ end: CGPoint) -> LineFit? {
        guard let direction = normalized(vector(from: start, to: end)) else { return nil }
        return LineFit(center: midpoint(start, end), direction: direction)
    }

    fileprivate static func intersection(_ lhs: LineFit, _ rhs: LineFit) -> CGPoint? {
        let denominator = cross(lhs.direction, rhs.direction)
        guard abs(denominator) > 0.05 else { return nil }
        let offset = vector(from: lhs.center, to: rhs.center)
        let parameter = cross(offset, rhs.direction) / denominator
        return lhs.center + lhs.direction * parameter
    }

    fileprivate static func centroid(of points: [CGPoint]) -> CGPoint {
        let total = points.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }
        let count = CGFloat(max(1, points.count))
        return CGPoint(x: total.x / count, y: total.y / count)
    }

    fileprivate static func boundingRect(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minimumX = first.x
        var maximumX = first.x
        var minimumY = first.y
        var maximumY = first.y
        for point in points.dropFirst() {
            minimumX = min(minimumX, point.x)
            maximumX = max(maximumX, point.x)
            minimumY = min(minimumY, point.y)
            maximumY = max(maximumY, point.y)
        }
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
    }

    fileprivate static func polylineLength(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 2 else { return 0 }
        return (1..<points.count).reduce(CGFloat.zero) {
            $0 + distance(points[$1 - 1], points[$1])
        }
    }

    fileprivate static func signedArea(of points: [CGPoint]) -> CGFloat {
        guard points.count >= 3 else { return 0 }
        return points.indices.reduce(CGFloat.zero) { area, index in
            let next = points[(index + 1) % points.count]
            return area + points[index].x * next.y - next.x * points[index].y
        } / 2
    }

    fileprivate static func distanceToSegment(_ point: CGPoint, _ start: CGPoint, _ end: CGPoint) -> CGFloat {
        let edge = vector(from: start, to: end)
        let lengthSquared = dot(edge, edge)
        guard lengthSquared > 0 else { return distance(point, start) }
        let progress = clamp(
            dot(vector(from: start, to: point), edge) / lengthSquared,
            minimum: 0,
            maximum: 1
        )
        return distance(point, start + edge * progress)
    }

    fileprivate static func point(
        axisX: CGVector,
        x: CGFloat,
        axisY: CGVector,
        y: CGFloat
    ) -> CGPoint {
        .zero + axisX * x + axisY * y
    }

    fileprivate static func interpolate(_ start: CGPoint, _ end: CGPoint, progress: CGFloat) -> CGPoint {
        CGPoint(
            x: start.x + (end.x - start.x) * progress,
            y: start.y + (end.y - start.y) * progress
        )
    }

    fileprivate static func midpoint(_ lhs: CGPoint, _ rhs: CGPoint) -> CGPoint {
        CGPoint(x: (lhs.x + rhs.x) / 2, y: (lhs.y + rhs.y) / 2)
    }

    fileprivate static func vector(from start: CGPoint, to end: CGPoint) -> CGVector {
        CGVector(dx: end.x - start.x, dy: end.y - start.y)
    }

    fileprivate static func normalized(_ vector: CGVector) -> CGVector? {
        let length = magnitude(vector)
        guard length > 0 else { return nil }
        return vector * (1 / length)
    }

    fileprivate static func magnitude(_ vector: CGVector) -> CGFloat {
        hypot(vector.dx, vector.dy)
    }

    fileprivate static func dot(_ lhs: CGVector, _ rhs: CGVector) -> CGFloat {
        lhs.dx * rhs.dx + lhs.dy * rhs.dy
    }

    fileprivate static func cross(_ lhs: CGVector, _ rhs: CGVector) -> CGFloat {
        lhs.dx * rhs.dy - lhs.dy * rhs.dx
    }

    fileprivate static func rotated(_ vector: CGVector, by angle: CGFloat) -> CGVector {
        CGVector(
            dx: vector.dx * cos(angle) - vector.dy * sin(angle),
            dy: vector.dx * sin(angle) + vector.dy * cos(angle)
        )
    }

    fileprivate static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    fileprivate static func squaredDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    fileprivate static func clamp(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(maximum, max(minimum, value))
    }
}

private prefix func - (vector: CGVector) -> CGVector {
    CGVector(dx: -vector.dx, dy: -vector.dy)
}

private func + (point: CGPoint, vector: CGVector) -> CGPoint {
    CGPoint(x: point.x + vector.dx, y: point.y + vector.dy)
}

private func * (vector: CGVector, scalar: CGFloat) -> CGVector {
    CGVector(dx: vector.dx * scalar, dy: vector.dy * scalar)
}
