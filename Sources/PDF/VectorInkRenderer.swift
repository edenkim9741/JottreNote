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
import UIKit

/// Writes PencilKit ink into a Core Graphics context as filled paths.
///
/// `PKDrawing.image(from:scale:)` would embed a fixed-resolution bitmap, which
/// visibly pixelates as soon as the reader zooms past the scale it was rendered
/// at. Converting each `PKStroke` to a `CGPath` keeps the ink resolution
/// independent, so a PDF stays sharp at any magnification.
enum VectorInkRenderer {

    private enum Constants {
        /// Spacing between interpolated stroke samples, in document points.
        /// Small enough that outline corners stay invisible at high zoom.
        static let sampleDistance = CGFloat(1.5)
        static let minimumRadius = CGFloat(0.1)
    }

    /// Draws every stroke of `drawing` that intersects `canvasRect`, translated
    /// so `canvasRect` lands on `pageBounds`.
    static func draw(
        drawing: PKDrawing,
        canvasRect: CGRect,
        pageBounds: CGRect,
        context: CGContext
    ) {
        context.saveGState()
        defer { context.restoreGState() }

        context.clip(to: pageBounds)
        context.translateBy(x: -canvasRect.minX, y: -canvasRect.minY)

        let lightTraits = UITraitCollection(userInterfaceStyle: .light)
        for stroke in drawing.strokes where stroke.renderBounds.intersects(canvasRect) {
            guard let vectorPath = makePath(for: stroke) else { continue }
            let color = stroke.ink.color.resolvedColor(with: lightTraits)

            context.saveGState()
            context.concatenate(stroke.transform)
            if let mask = stroke.mask {
                context.addPath(mask.cgPath)
                context.clip()
            }
            context.setFillColor(color.cgColor)
            context.setAlpha(vectorPath.opacity)
            if stroke.ink.inkType == .marker {
                context.setBlendMode(.multiply)
            }
            context.addPath(vectorPath.path)
            context.fillPath()
            context.restoreGState()
        }
    }

    private struct VectorPath {
        let path: CGPath
        let opacity: CGFloat
    }

    private static func makePath(for stroke: PKStroke) -> VectorPath? {
        let path = CGMutablePath()
        var opacityTotal = CGFloat.zero
        var opacitySampleCount = 0

        let ranges = stroke.maskedPathRanges
        if ranges.isEmpty {
            let points: [PKStrokePoint]
            if stroke.path.count > 1 {
                points = Array(
                    stroke.path.interpolatedPoints(
                        in: 0...CGFloat(stroke.path.count - 1),
                        by: .distance(Constants.sampleDistance)
                    )
                )
            } else {
                points = Array(stroke.path)
            }
            appendOutline(
                points: points,
                to: path,
                opacityTotal: &opacityTotal,
                opacitySampleCount: &opacitySampleCount
            )
        } else {
            for range in ranges {
                let points = Array(
                    stroke.path.interpolatedPoints(
                        in: range,
                        by: .distance(Constants.sampleDistance)
                    )
                )
                appendOutline(
                    points: points,
                    to: path,
                    opacityTotal: &opacityTotal,
                    opacitySampleCount: &opacitySampleCount
                )
            }
        }

        guard !path.isEmpty else { return nil }
        let opacity =
            opacitySampleCount > 0
            ? max(0, min(1, opacityTotal / CGFloat(opacitySampleCount)))
            : 1
        return VectorPath(path: path, opacity: opacity)
    }

    /// Builds a closed outline by offsetting each sample along the stroke normal
    /// by its own radius, then caps both ends with a circle.
    private static func appendOutline(
        points: [PKStrokePoint],
        to path: CGMutablePath,
        opacityTotal: inout CGFloat,
        opacitySampleCount: inout Int
    ) {
        let samples = points.compactMap { point -> (location: CGPoint, radius: CGFloat)? in
            guard point.location.x.isFinite, point.location.y.isFinite else { return nil }
            let radius = CGFloat(
                max(
                    Double(Constants.minimumRadius),
                    max(abs(point.size.width), abs(point.size.height)) * 0.5
                )
            )
            opacityTotal += max(0, min(1, point.opacity))
            opacitySampleCount += 1
            return (point.location, radius)
        }
        guard let first = samples.first else { return }

        if samples.count == 1 {
            path.addEllipse(
                in: CGRect(
                    x: first.location.x - first.radius,
                    y: first.location.y - first.radius,
                    width: first.radius * 2,
                    height: first.radius * 2
                )
            )
            return
        }

        var leftEdge: [CGPoint] = []
        var rightEdge: [CGPoint] = []
        leftEdge.reserveCapacity(samples.count)
        rightEdge.reserveCapacity(samples.count)

        for index in samples.indices {
            let previous = samples[index > samples.startIndex ? samples.index(before: index) : index]
                .location
            let next = samples[
                index < samples.index(before: samples.endIndex)
                    ? samples.index(after: index)
                    : index
            ].location
            let tangent = CGPoint(x: next.x - previous.x, y: next.y - previous.y)
            let length = hypot(tangent.x, tangent.y)
            let normal =
                length > 0.0001
                ? CGPoint(x: -tangent.y / length, y: tangent.x / length)
                : CGPoint(x: 0, y: 1)
            let sample = samples[index]
            leftEdge.append(
                CGPoint(
                    x: sample.location.x + normal.x * sample.radius,
                    y: sample.location.y + normal.y * sample.radius
                )
            )
            rightEdge.append(
                CGPoint(
                    x: sample.location.x - normal.x * sample.radius,
                    y: sample.location.y - normal.y * sample.radius
                )
            )
        }

        path.move(to: leftEdge[0])
        for point in leftEdge.dropFirst() {
            path.addLine(to: point)
        }
        for point in rightEdge.reversed() {
            path.addLine(to: point)
        }
        path.closeSubpath()

        for sample in [first, samples[samples.index(before: samples.endIndex)]] {
            path.addEllipse(
                in: CGRect(
                    x: sample.location.x - sample.radius,
                    y: sample.location.y - sample.radius,
                    width: sample.radius * 2,
                    height: sample.radius * 2
                )
            )
        }
    }
}
