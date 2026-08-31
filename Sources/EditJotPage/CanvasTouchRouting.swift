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

/// Decides how many fingers document navigation needs on the drawing canvas.
///
/// `PKCanvasView` is itself a scroll view, and this editor lets it own document
/// pan and zoom so PencilKit re-renders ink at the zoomed resolution. PencilKit
/// arbitrates its drawing recognizer against its own navigation gestures, so
/// the app only supplies the finger count and leaves `drawingPolicy` as the
/// source of truth for what may draw.
@MainActor
enum CanvasTouchRouting {

    struct Configuration: Equatable, Sendable {
        let isFingerDrawingEnabled: Bool

        var documentPanMinimumNumberOfTouches: Int {
            isFingerDrawingEnabled ? 2 : 1
        }

        var routesDirectTouchesToDocumentScroll: Bool {
            !isFingerDrawingEnabled
        }
    }

    /// Resolves PencilKit's drawing policy without mutating it.
    ///
    /// The `.default` policy accepts direct drawing only while a tool picker is
    /// visible and the system's Apple Pencil-only preference is disabled. A
    /// non-editing canvas always gives a one-finger drag to document scrolling.
    static func configuration(
        isEditingEnabled: Bool,
        drawingPolicy: PKCanvasViewDrawingPolicy,
        isToolPickerVisible: Bool,
        prefersPencilOnlyDrawing: Bool
    ) -> Configuration {
        guard isEditingEnabled else {
            return Configuration(isFingerDrawingEnabled: false)
        }

        let isFingerDrawingEnabled: Bool
        switch drawingPolicy {
        case .anyInput:
            isFingerDrawingEnabled = true
        case .pencilOnly:
            isFingerDrawingEnabled = false
        case .default:
            isFingerDrawingEnabled = isToolPickerVisible && !prefersPencilOnlyDrawing
        @unknown default:
            isFingerDrawingEnabled = false
        }

        return Configuration(isFingerDrawingEnabled: isFingerDrawingEnabled)
    }

    /// Configures navigation on the canvas that owns document scrolling.
    ///
    /// PencilKit arbitrates its own drawing recognizer against its scroll and
    /// zoom gestures, so the only thing left to decide is how many fingers a
    /// pan needs: one when the pencil draws, two when a finger also draws.
    /// Apple recommends expressing drawing input through `drawingPolicy` rather
    /// than by editing `drawingGestureRecognizer.allowedTouchTypes`.
    static func apply(
        _ configuration: Configuration,
        to documentCanvasView: PKCanvasView
    ) {
        #if !targetEnvironment(macCatalyst)
        if !documentCanvasView.isScrollEnabled {
            documentCanvasView.isScrollEnabled = true
        }
        if !documentCanvasView.panGestureRecognizer.isEnabled {
            documentCanvasView.panGestureRecognizer.isEnabled = true
        }
        // Raise the upper bound first so moving away from a one-touch
        // configuration can never briefly describe an invalid range.
        if documentCanvasView.panGestureRecognizer.maximumNumberOfTouches != 2 {
            documentCanvasView.panGestureRecognizer.maximumNumberOfTouches = 2
        }
        if documentCanvasView.panGestureRecognizer.minimumNumberOfTouches
            != configuration.documentPanMinimumNumberOfTouches
        {
            documentCanvasView.panGestureRecognizer.minimumNumberOfTouches =
                configuration.documentPanMinimumNumberOfTouches
        }
        #endif
    }
}

/// Decides whether a direct single tap should be kept away from PencilKit's
/// blank-canvas edit-menu recognizer. Lasso and finger-drawing modes remain
/// entirely native so selection, manipulation, and dot input are unaffected.
enum CanvasEditMenuSuppressionPolicy {

    static func blocksDirectTouch(
        isEditingEnabled: Bool,
        isLassoTool: Bool,
        routesDirectTouchesToDocumentScroll: Bool
    ) -> Bool {
        isEditingEnabled && !isLassoTool && routesDirectTouchesToDocumentScroll
    }
}


