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
import UIKit
import XCTest

@testable import Jottre

final class PencilStrokeShapeSnapperTests: XCTestCase {

    func testSnapsNoisyLineUsingAnOrientedFit() throws {
        let angle = CGFloat.pi / 5
        let direction = CGVector(dx: cos(angle), dy: sin(angle))
        let normal = CGVector(dx: -direction.dy, dy: direction.dx)
        let points = (0..<48).map { index in
            let progress = CGFloat(index) / 47
            return CGPoint(x: 30, y: 40)
                + direction * (220 * progress)
                + normal * (sin(CGFloat(index) * 1.7) * 1.8)
        }

        let result = try XCTUnwrap(PencilStrokeShapeSnapper.snap(makeStroke(points)))

        XCTAssertEqual(result.shape, .line)
        let locations = Array(result.stroke.path).map(\.location)
        XCTAssertLessThan(distance(locations.first!, CGPoint(x: 30, y: 40)), 5)
        XCTAssertLessThan(distance(locations.last!, CGPoint(x: 30, y: 40) + direction * 220), 5)
    }

    func testSnapsCircleAndClosesThePath() throws {
        let points = ellipsePoints(
            center: CGPoint(x: 140, y: 180),
            radiusX: 70,
            radiusY: 68,
            rotation: 0.3
        )

        let result = try XCTUnwrap(PencilStrokeShapeSnapper.snap(makeStroke(points)))

        XCTAssertEqual(result.shape, .circle)
        let locations = Array(result.stroke.path).map(\.location)
        XCTAssertLessThan(distance(locations.first!, locations.last!), 0.01)
        XCTAssertGreaterThan(locations.count, 64)
    }

    func testSnapsRotatedEllipse() throws {
        let points = ellipsePoints(
            center: CGPoint(x: 180, y: 150),
            radiusX: 105,
            radiusY: 48,
            rotation: .pi / 6
        )

        let result = try XCTUnwrap(PencilStrokeShapeSnapper.snap(makeStroke(points)))

        XCTAssertEqual(result.shape, .ellipse)
        let bounds = result.stroke.renderBounds
        XCTAssertGreaterThan(bounds.width, 150)
        XCTAssertGreaterThan(bounds.height, 80)
    }

    func testSnapsRotatedRectangleWithSharpSplineCorners() throws {
        let expected = rotated(
            [
                CGPoint(x: -90, y: -50),
                CGPoint(x: 90, y: -50),
                CGPoint(x: 90, y: 50),
                CGPoint(x: -90, y: 50),
            ],
            around: .zero,
            by: .pi / 5,
            offset: CGPoint(x: 220, y: 170)
        )
        let points = noisyPolyline(vertices: expected, closed: true, samplesPerEdge: 24)

        let result = try XCTUnwrap(PencilStrokeShapeSnapper.snap(makeStroke(points)))

        XCTAssertEqual(result.shape, .rectangle)
        let controls = Array(result.stroke.path).map(\.location)
        XCTAssertEqual(controls.count, 15)
        for cornerStart in stride(from: 0, through: 9, by: 3) {
            XCTAssertLessThan(distance(controls[cornerStart], controls[cornerStart + 1]), 0.001)
            XCTAssertLessThan(distance(controls[cornerStart], controls[cornerStart + 2]), 0.001)
        }
        XCTAssertLessThan(distance(controls[0], controls[12]), 0.001)
    }

    func testSnapsRotatedTriangle() throws {
        let expected = rotated(
            [CGPoint(x: 0, y: -100), CGPoint(x: 95, y: 75), CGPoint(x: -95, y: 75)],
            around: .zero,
            by: -.pi / 7,
            offset: CGPoint(x: 180, y: 190)
        )
        let points = noisyPolyline(vertices: expected, closed: true, samplesPerEdge: 28)

        let result = try XCTUnwrap(PencilStrokeShapeSnapper.snap(makeStroke(points)))

        XCTAssertEqual(result.shape, .triangle)
        XCTAssertEqual(result.stroke.path.count, 12)
        XCTAssertLessThan(
            distance(result.stroke.path.first!.location, result.stroke.path.last!.location),
            0.001
        )
    }

    func testSnapsOneStrokeArrowAndLeavesItOpen() throws {
        let vertices = [
            CGPoint(x: 30, y: 150),
            CGPoint(x: 250, y: 110),
            CGPoint(x: 190, y: 75),
            CGPoint(x: 250, y: 110),
            CGPoint(x: 207, y: 165),
        ]
        let points = noisyPolyline(vertices: vertices, closed: false, samplesPerEdge: 22)

        let result = try XCTUnwrap(PencilStrokeShapeSnapper.snap(makeStroke(points)))

        XCTAssertEqual(result.shape, .arrow)
        XCTAssertEqual(result.stroke.path.count, 15)
        XCTAssertGreaterThan(
            distance(result.stroke.path.first!.location, result.stroke.path.last!.location),
            30
        )
    }

    func testSnapsArrowDrawnFromTheHeadBackToTheTail() throws {
        let vertices = [
            CGPoint(x: 207, y: 165),
            CGPoint(x: 250, y: 110),
            CGPoint(x: 190, y: 75),
            CGPoint(x: 250, y: 110),
            CGPoint(x: 30, y: 150),
        ]
        let points = noisyPolyline(vertices: vertices, closed: false, samplesPerEdge: 22)

        let result = try XCTUnwrap(PencilStrokeShapeSnapper.snap(makeStroke(points)))

        XCTAssertEqual(result.shape, .arrow)
        XCTAssertEqual(result.stroke.path.count, 15)
    }

    func testRejectsShortStrokeAndFreehandCurve() {
        XCTAssertNil(
            PencilStrokeShapeSnapper.snap(
                makeStroke([
                    CGPoint(x: 0, y: 0),
                    CGPoint(x: 8, y: 2),
                ])
            )
        )

        let curve = (0..<80).map { index in
            let x = CGFloat(index) * 3
            return CGPoint(x: x, y: 80 + sin(x / 18) * 38)
        }
        XCTAssertNil(PencilStrokeShapeSnapper.snap(makeStroke(curve)))
    }

    func testPreservesInkTransformCreationDateAndRandomSeed() throws {
        let date = Date(timeIntervalSinceReferenceDate: 123_456)
        let transform = CGAffineTransform(rotationAngle: 0.15).translatedBy(x: 12, y: 34)
        let ink = PKInk(.pen, color: .systemPurple)
        let source = makeStroke(
            (0..<30).map { CGPoint(x: CGFloat($0) * 5, y: 20) },
            ink: ink,
            transform: transform,
            creationDate: date,
            randomSeed: 0x1234_ABCD
        )

        let snapped = try XCTUnwrap(PencilStrokeShapeSnapper.snap(source)?.stroke)

        XCTAssertEqual(snapped.ink.inkType, source.ink.inkType)
        XCTAssertTrue(snapped.ink.color.isEqual(source.ink.color))
        XCTAssertEqual(snapped.transform, transform)
        XCTAssertEqual(snapped.path.creationDate, date)
        XCTAssertEqual(snapped.randomSeed, 0x1234_ABCD)
        XCTAssertNil(snapped.mask)
    }

    func testSnappedStrokeRoundTripsThroughPencilKitSerialization() throws {
        let source = makeStroke(
            ellipsePoints(
                center: CGPoint(x: 120, y: 150),
                radiusX: 72,
                radiusY: 40,
                rotation: .pi / 8
            ),
            ink: PKInk(.pencil, color: .systemBlue),
            randomSeed: 73
        )
        let result = try XCTUnwrap(PencilStrokeShapeSnapper.snap(source))

        let encoded = PKDrawing(strokes: [result.stroke]).dataRepresentation()
        let decoded = try PKDrawing(data: encoded)
        let roundTripped = try XCTUnwrap(decoded.strokes.first)

        XCTAssertEqual(roundTripped.ink.inkType, source.ink.inkType)
        XCTAssertEqual(roundTripped.randomSeed, source.randomSeed)
        XCTAssertEqual(roundTripped.path.count, result.stroke.path.count)
        XCTAssertLessThan(
            distance(roundTripped.path.first!.location, result.stroke.path.first!.location),
            0.001
        )
    }
}

extension PencilStrokeShapeSnapperTests {

    fileprivate func makeStroke(
        _ locations: [CGPoint],
        ink: PKInk = PKInk(.pen, color: .black),
        transform: CGAffineTransform = .identity,
        creationDate: Date = Date(timeIntervalSinceReferenceDate: 1_000),
        randomSeed: UInt32 = 42
    ) -> PKStroke {
        let points = locations.enumerated().map { index, location in
            PKStrokePoint(
                location: location,
                timeOffset: Double(index) * 0.01,
                size: CGSize(width: 5, height: 5),
                opacity: 0.9,
                force: 0.7,
                azimuth: 0.2,
                altitude: 1.1
            )
        }
        return PKStroke(
            ink: ink,
            path: PKStrokePath(controlPoints: points, creationDate: creationDate),
            transform: transform,
            mask: nil,
            randomSeed: randomSeed
        )
    }

    fileprivate func ellipsePoints(
        center: CGPoint,
        radiusX: CGFloat,
        radiusY: CGFloat,
        rotation: CGFloat
    ) -> [CGPoint] {
        let axisX = CGVector(dx: cos(rotation), dy: sin(rotation))
        let axisY = CGVector(dx: -sin(rotation), dy: cos(rotation))
        return (0...96).map { index in
            let angle = 2 * CGFloat.pi * CGFloat(index) / 96
            let noise = sin(CGFloat(index) * 1.73) * 1.2
            return center
                + axisX * (cos(angle) * (radiusX + noise))
                + axisY * (sin(angle) * (radiusY + noise))
        }
    }

    fileprivate func noisyPolyline(
        vertices: [CGPoint],
        closed: Bool,
        samplesPerEdge: Int
    ) -> [CGPoint] {
        let edgeCount = closed ? vertices.count : vertices.count - 1
        var result: [CGPoint] = []
        for edgeIndex in 0..<edgeCount {
            let start = vertices[edgeIndex]
            let end = vertices[(edgeIndex + 1) % vertices.count]
            let edge = CGVector(dx: end.x - start.x, dy: end.y - start.y)
            let length = hypot(edge.dx, edge.dy)
            let normal = CGVector(dx: -edge.dy / length, dy: edge.dx / length)
            for sampleIndex in 0..<samplesPerEdge {
                let progress = CGFloat(sampleIndex) / CGFloat(samplesPerEdge)
                let base = CGPoint(
                    x: start.x + edge.dx * progress,
                    y: start.y + edge.dy * progress
                )
                let sequence = CGFloat(edgeIndex * samplesPerEdge + sampleIndex)
                result.append(base + normal * (sin(sequence * 1.91) * 1.15))
            }
        }
        result.append(closed ? vertices[0] : vertices[vertices.count - 1])
        return result
    }

    fileprivate func rotated(
        _ points: [CGPoint],
        around center: CGPoint,
        by angle: CGFloat,
        offset: CGPoint
    ) -> [CGPoint] {
        points.map { point in
            let dx = point.x - center.x
            let dy = point.y - center.y
            return CGPoint(
                x: center.x + dx * cos(angle) - dy * sin(angle) + offset.x,
                y: center.y + dx * sin(angle) + dy * cos(angle) + offset.y
            )
        }
    }

    fileprivate func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}

private func + (point: CGPoint, vector: CGVector) -> CGPoint {
    CGPoint(x: point.x + vector.dx, y: point.y + vector.dy)
}

private func * (vector: CGVector, scalar: CGFloat) -> CGVector {
    CGVector(dx: vector.dx * scalar, dy: vector.dy * scalar)
}
