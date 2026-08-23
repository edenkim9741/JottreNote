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

/// Owns the canonical drawing and the two PencilKit presentation planes.
///
/// Pen and marker input stay on their final canvas for the entire gesture. A
/// normal stroke commit therefore updates only the model snapshot; it never
/// replaces either canvas drawing. Lasso and eraser temporarily use a combined
/// presentation because PencilKit must see every stroke to edit it.
@MainActor
final class JotInkCanvasCoordinator {

    enum Mode: Equatable, Sendable {
        case highlighter
        case foreground
        case combined

        fileprivate var usesSplitPresentation: Bool {
            self != .combined
        }
    }

    enum Role: Equatable, Sendable {
        case highlighter
        case foreground
    }

    private let highlighterCanvas: PKCanvasView
    private let foregroundCanvas: PKCanvasView

    private(set) var mode = Mode.foreground
    private(set) var committedDrawing = PKDrawing()
    private(set) var committedStrokePageIndices: [Int] = []
    private(set) var partition = JotDrawingLayerPartition(drawing: PKDrawing())

    private var liveRevision = UInt64.zero
    private var committedRevision = UInt64.zero
    private var isApplyingPresentation = false
    private var expectedProgrammaticDrawings: [ObjectIdentifier: PKDrawing] = [:]

    init(highlighterCanvas: PKCanvasView, foregroundCanvas: PKCanvasView) {
        self.highlighterCanvas = highlighterCanvas
        self.foregroundCanvas = foregroundCanvas
    }

    var activeCanvas: PKCanvasView {
        mode == .highlighter ? highlighterCanvas : foregroundCanvas
    }

    var hasUncommittedChanges: Bool {
        liveRevision != committedRevision
    }

    func role(of canvas: PKCanvasView) -> Role? {
        if canvas === highlighterCanvas { return .highlighter }
        if canvas === foregroundCanvas { return .foreground }
        return nil
    }

    func load(drawing: PKDrawing, strokePageIndices: [Int]) {
        let partition = JotDrawingLayerPartition(
            drawing: drawing,
            strokePageIndices: strokePageIndices
        )
        self.partition = partition
        committedDrawing = partition.combined
        committedStrokePageIndices = partition.combinedPageIndices
        applyCurrentPresentation()
        liveRevision &+= 1
        committedRevision = liveRevision
    }

    /// Changes only the visual representation required by the selected tool.
    /// Moving between pen and marker keeps both canvases untouched.
    @discardableResult
    func transition(to nextMode: Mode) -> Bool {
        guard mode != nextMode else { return false }
        let previousMode = mode
        mode = nextMode
        if previousMode.usesSplitPresentation != nextMode.usesSplitPresentation {
            applyCurrentPresentation()
        }
        return true
    }

    /// Records a PencilKit delegate callback. Programmatic presentation changes
    /// are consumed without being mistaken for user edits, including callbacks
    /// delivered on a later run-loop turn.
    @discardableResult
    func noteDrawingDidChange(from canvas: PKCanvasView) -> Bool {
        guard role(of: canvas) != nil else { return false }
        let identifier = ObjectIdentifier(canvas)
        if let expected = expectedProgrammaticDrawings[identifier] {
            // PencilKit can emit more than one delayed callback for a single
            // assignment. Keep suppressing callbacks while the canvas still
            // contains the programmatically supplied drawing; the first real
            // user edit changes that value and clears the expectation below.
            if expected == canvas.drawing { return false }
            expectedProgrammaticDrawings[identifier] = nil
        }
        guard !isApplyingPresentation else { return false }
        liveRevision &+= 1
        return true
    }

    /// Replaces one canvas for an intentional edit such as shape snapping and
    /// records exactly one logical mutation regardless of delegate timing.
    func replaceDrawing(_ drawing: PKDrawing, on canvas: PKCanvasView) {
        guard role(of: canvas) != nil, canvas.drawing != drawing else { return }
        setDrawing(drawing, on: canvas)
        liveRevision &+= 1
    }

    func liveCombinedDrawing() -> PKDrawing {
        switch mode {
        case .combined:
            return foregroundCanvas.drawing
        case .highlighter, .foreground:
            return PKDrawing(
                strokes: highlighterCanvas.drawing.strokes
                    + foregroundCanvas.drawing.strokes
            )
        }
    }

    /// Commits the live canvases into markers-first canonical order without
    /// changing their presentation. This is the stroke-end hot path.
    @discardableResult
    func commitLiveDrawing(
        _ liveDrawing: PKDrawing,
        strokePageIndices: [Int]
    ) -> PKDrawing {
        let partition = JotDrawingLayerPartition(
            drawing: liveDrawing,
            strokePageIndices: strokePageIndices
        )
        self.partition = partition
        committedDrawing = partition.combined
        committedStrokePageIndices = partition.combinedPageIndices
        committedRevision = liveRevision
        return committedDrawing
    }

    private func applyCurrentPresentation() {
        isApplyingPresentation = true
        defer { isApplyingPresentation = false }

        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            switch mode {
            case .combined:
                setDrawing(PKDrawing(), on: highlighterCanvas)
                setDrawing(partition.combined, on: foregroundCanvas)
            case .highlighter, .foreground:
                setDrawing(partition.highlighter, on: highlighterCanvas)
                setDrawing(partition.foreground, on: foregroundCanvas)
            }
            CATransaction.commit()
        }
    }

    private func setDrawing(_ drawing: PKDrawing, on canvas: PKCanvasView) {
        guard canvas.drawing != drawing else { return }
        expectedProgrammaticDrawings[ObjectIdentifier(canvas)] = drawing
        canvas.drawing = drawing
    }
}
