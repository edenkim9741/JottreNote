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

/// Writes PencilKit ink into a Core Graphics context using PencilKit's own
/// renderer. Keeping export on the same rendering path as the canvas avoids
/// approximating stroke outlines, caps, pressure, and opacity ourselves.
enum VectorInkRenderer {

    private enum Constants {
        static let renderingScale = CGFloat(2)
    }

    /// Draws every stroke of `drawing` that intersects `canvasRect`, translated
    /// so `canvasRect` lands on `pageBounds`.
    static func draw(
        drawing: PKDrawing,
        canvasRect: CGRect,
        pageBounds: CGRect,
        context: CGContext
    ) {
        guard !drawing.strokes.isEmpty else { return }

        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: canvasRect, scale: Constants.renderingScale)
        }

        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: pageBounds)
        image.draw(
            in: pageBounds,
            blendMode: drawing.strokes.contains { $0.ink.inkType == .marker }
                ? .multiply
                : .normal,
            alpha: 1
        )
    }
}
