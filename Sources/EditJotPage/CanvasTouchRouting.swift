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

/// Routes direct touches between PencilKit and the document scroll view.
///
/// `PKCanvasView` is itself a scroll view and owns additional selection gesture
/// recognizers that can appear while the lasso remains active. This editor uses
/// a separate document scroll view. When finger drawing is disabled, an
/// app-owned navigation recognizer prevents PencilKit's transient selection
/// gestures from preempting document scrolling. PencilKit continues to own
/// Apple Pencil input and its drawing policy remains the source of truth.
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

    /// Applies navigation settings without modifying PencilKit's drawing
    /// recognizer. Apple recommends using `drawingPolicy`, rather than changing
    /// `drawingGestureRecognizer.allowedTouchTypes`, to control drawing input.
    static func apply(
        _ configuration: Configuration,
        to canvasViews: [PKCanvasView],
        documentScrollView: UIScrollView
    ) {
        #if !targetEnvironment(macCatalyst)
        let directTouch = NSNumber(value: UITouch.TouchType.direct.rawValue)
        let directTouches = [directTouch]

        if documentScrollView.panGestureRecognizer.allowedTouchTypes != directTouches {
            documentScrollView.panGestureRecognizer.allowedTouchTypes = directTouches
        }
        // Set the upper bound first so transitioning from a custom one-touch
        // configuration can never temporarily create an invalid range.
        if documentScrollView.panGestureRecognizer.maximumNumberOfTouches != 2 {
            documentScrollView.panGestureRecognizer.maximumNumberOfTouches = 2
        }
        if documentScrollView.panGestureRecognizer.minimumNumberOfTouches
            != configuration.documentPanMinimumNumberOfTouches
        {
            documentScrollView.panGestureRecognizer.minimumNumberOfTouches =
                configuration.documentPanMinimumNumberOfTouches
        }
        if documentScrollView.pinchGestureRecognizer?.allowedTouchTypes != directTouches {
            documentScrollView.pinchGestureRecognizer?.allowedTouchTypes = directTouches
        }

        for canvasView in canvasViews {
            // The outer document scroll view is the sole owner of pan and zoom.
            if canvasView.isScrollEnabled {
                canvasView.isScrollEnabled = false
            }
            if canvasView.panGestureRecognizer.isEnabled {
                canvasView.panGestureRecognizer.isEnabled = false
            }
        }

        if let documentScrollView = documentScrollView as? JotDocumentScrollView {
            documentScrollView.protectNavigation(
                from: canvasViews.map(\.drawingGestureRecognizer)
            )
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

/// Keeps a direct-touch navigation pan from being preempted by transient
/// PencilKit selection recognizers.
///
/// It never receives Apple Pencil touches. The native document pan and pinch
/// recognizers remain simultaneous partners, while recognizers installed on
/// descendant selection views cannot permanently take ownership of the next
/// finger pan.
@MainActor
private final class DirectTouchNavigationPanGestureRecognizer: UIPanGestureRecognizer {

    weak var documentPanGestureRecognizer: UIGestureRecognizer?
    weak var documentPinchGestureRecognizer: UIGestureRecognizer?
    var pencilKitDrawingGestureRecognizers: [UIGestureRecognizer] = []

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        if isNavigationRecognizer(preventedGestureRecognizer)
            || isPencilKitDrawingRecognizer(preventedGestureRecognizer)
        {
            return false
        }
        return belongsToDocumentDescendant(preventedGestureRecognizer)
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        if isNavigationRecognizer(preventingGestureRecognizer) {
            return false
        }
        if isPencilKitDrawingRecognizer(preventingGestureRecognizer) {
            return true
        }
        if belongsToDocumentDescendant(preventingGestureRecognizer) {
            return false
        }
        // Keep system and ancestor gestures, such as the screen-edge back
        // gesture, outside the document's arbitration policy.
        return true
    }

    private func isNavigationRecognizer(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === documentPanGestureRecognizer
            || gestureRecognizer === documentPinchGestureRecognizer
    }

    private func isPencilKitDrawingRecognizer(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        pencilKitDrawingGestureRecognizers.contains {
            $0 === gestureRecognizer
        }
    }

    private func belongsToDocumentDescendant(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let documentView = view,
            let gestureView = gestureRecognizer.view,
            gestureView !== documentView
        else { return false }
        return gestureView.isDescendant(of: documentView)
    }
}

/// The outer scroll view owns finger navigation. A lightweight pan gate uses
/// the real `UITouch.type` supplied by the gesture delegate, avoiding the
/// unreliable touch inference previously performed from `UIEvent` in hit-test.
@MainActor
final class JotDocumentScrollView: UIScrollView, UIGestureRecognizerDelegate {

    var shouldRouteDirectTouch: (() -> Bool)?

    private lazy var directTouchNavigationGestureRecognizer: DirectTouchNavigationPanGestureRecognizer = {
        let gestureRecognizer = DirectTouchNavigationPanGestureRecognizer(target: nil, action: nil)
        gestureRecognizer.name = "Jottre.DirectTouchNavigation"
        gestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ]
        gestureRecognizer.minimumNumberOfTouches = 1
        gestureRecognizer.maximumNumberOfTouches = 2
        gestureRecognizer.requiresExclusiveTouchType = true
        gestureRecognizer.cancelsTouchesInView = true
        gestureRecognizer.documentPanGestureRecognizer = panGestureRecognizer
        gestureRecognizer.documentPinchGestureRecognizer = pinchGestureRecognizer
        gestureRecognizer.addTarget(
            self,
            action: #selector(handleDirectTouchNavigation(_:))
        )
        gestureRecognizer.delegate = self
        return gestureRecognizer
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(directTouchNavigationGestureRecognizer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addGestureRecognizer(directTouchNavigationGestureRecognizer)
    }

    func protectNavigation(from drawingGestureRecognizers: [UIGestureRecognizer]) {
        directTouchNavigationGestureRecognizer.pencilKitDrawingGestureRecognizers =
            drawingGestureRecognizers
    }

    @objc
    private func handleDirectTouchNavigation(_ gestureRecognizer: UIPanGestureRecognizer) {
        // Recognition itself is the signal. The native scroll-view pan applies
        // translation and deceleration while recognizing simultaneously.
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard gestureRecognizer === directTouchNavigationGestureRecognizer else { return true }
        return touch.type == .direct && shouldRouteDirectTouch?() == true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === directTouchNavigationGestureRecognizer else { return false }
        return otherGestureRecognizer === panGestureRecognizer
            || otherGestureRecognizer === pinchGestureRecognizer
    }
}
