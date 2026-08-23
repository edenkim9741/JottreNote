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

/// A stable partition of a PencilKit drawing into the two visual ink planes
/// used by the editor and every export renderer.
///
/// Marker strokes are deliberately stored first in the combined drawing. This
/// keeps the `.jot` payload backwards compatible (it is still one `PKDrawing`)
/// while also giving old readers the best possible ink-on-ink ordering.
struct JotDrawingLayerPartition: Sendable {

    let highlighter: PKDrawing
    let foreground: PKDrawing
    let highlighterPageIndices: [Int]
    let foregroundPageIndices: [Int]

    var combined: PKDrawing {
        PKDrawing(strokes: highlighter.strokes + foreground.strokes)
    }

    var combinedPageIndices: [Int] {
        highlighterPageIndices + foregroundPageIndices
    }

    init(drawing: PKDrawing, strokePageIndices: [Int] = []) {
        var highlighterStrokes: [PKStroke] = []
        var foregroundStrokes: [PKStroke] = []
        var highlighterIndices: [Int] = []
        var foregroundIndices: [Int] = []

        highlighterStrokes.reserveCapacity(drawing.strokes.count)
        foregroundStrokes.reserveCapacity(drawing.strokes.count)
        highlighterIndices.reserveCapacity(strokePageIndices.count)
        foregroundIndices.reserveCapacity(strokePageIndices.count)

        for (index, stroke) in drawing.strokes.enumerated() {
            let pageIndex =
                strokePageIndices.indices.contains(index)
                ? max(0, strokePageIndices[index])
                : 0
            if stroke.ink.inkType == .marker {
                highlighterStrokes.append(stroke)
                highlighterIndices.append(pageIndex)
            } else {
                foregroundStrokes.append(stroke)
                foregroundIndices.append(pageIndex)
            }
        }

        highlighter = PKDrawing(strokes: highlighterStrokes)
        foreground = PKDrawing(strokes: foregroundStrokes)
        highlighterPageIndices = highlighterIndices
        foregroundPageIndices = foregroundIndices
    }
}
