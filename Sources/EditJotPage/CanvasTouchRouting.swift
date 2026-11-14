@preconcurrency import PencilKit
import UIKit

/// Separates PencilKit input from PDFKit document navigation.
@MainActor
enum CanvasTouchRouting {
    @MainActor
    private final class OriginalPDFPanConfiguration: NSObject {
        let allowedTouchTypes: [NSNumber]
        let minimumNumberOfTouches: Int
        let maximumNumberOfTouches: Int

        init(pan: UIPanGestureRecognizer) {
            allowedTouchTypes = pan.allowedTouchTypes
            minimumNumberOfTouches = pan.minimumNumberOfTouches
            maximumNumberOfTouches = pan.maximumNumberOfTouches
        }
    }

    private static let originalPDFPanConfigurations =
        NSMapTable<UIPanGestureRecognizer, OriginalPDFPanConfiguration>.weakToStrongObjects()

    static func usesPersistentResponder(isEditing: Bool, tool: any PKTool) -> Bool {
        isEditing && !(tool is PKLassoTool)
    }

    static func drawingPolicy(for _: PKTool) -> PKCanvasViewDrawingPolicy {
        #if DEBUG && targetEnvironment(simulator)
        if EditorInteractionFixture.tool == "scribble-undo"
            || EditorInteractionFixture.tool == "zoom-memory" { return .anyInput }
        #endif
        // PencilKit owns native inking, erasing and lasso interactions. Fingers
        // stay available to PDFKit for document navigation and zoom gestures.
        return .pencilOnly
    }

    static func suppressesStandardEditActions(isEditing: Bool, tool: any PKTool) -> Bool {
        isEditing && !(tool is PKLassoTool)
    }

    static func shouldSuppressNativeEditMenuInteractions(isEditing: Bool, tool: any PKTool) -> Bool {
        isEditing && !(tool is PKLassoTool)
    }

    /// PencilKit owns Pencil input; PDFKit navigation accepts one direct touch
    /// and permits two-touch navigation while editing. Restore the complete
    /// original pan configuration when editing ends. Never mutate an in-flight recognizer.
    static func apply(
        to panGestureRecognizers: [UIPanGestureRecognizer],
        pencilInputHasPriority: Bool = false
    ) {
        #if !targetEnvironment(macCatalyst)
        for pan in panGestureRecognizers {
            guard pan.state != .began, pan.state != .changed, pan.numberOfTouches == 0 else { continue }
            if pencilInputHasPriority {
                if originalPDFPanConfigurations.object(forKey: pan) == nil {
                    originalPDFPanConfigurations.setObject(OriginalPDFPanConfiguration(pan: pan), forKey: pan)
                }
#if DEBUG && targetEnvironment(simulator)
                if EditorInteractionFixture.tool == "scribble-undo" {
                    // This fixture maps XCTest's direct touch to PencilKit
                    // input. Keep PDFKit and the editor fallback from claiming
                    // that synthetic ink touch; production Pencil input remains
                    // separate from direct-touch PDF navigation.
                    let pencilTouch = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
                    if pan.allowedTouchTypes != pencilTouch { pan.allowedTouchTypes = pencilTouch }
                    if pan.minimumNumberOfTouches != 1 { pan.minimumNumberOfTouches = 1 }
                    if pan.maximumNumberOfTouches < 2 { pan.maximumNumberOfTouches = 2 }
                    continue
                }
#endif
                let directTouch = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                if pan.allowedTouchTypes != directTouch { pan.allowedTouchTypes = directTouch }
                if pan.minimumNumberOfTouches != 1 { pan.minimumNumberOfTouches = 1 }
                if pan.maximumNumberOfTouches < 2 { pan.maximumNumberOfTouches = 2 }
            } else if let original = originalPDFPanConfigurations.object(forKey: pan) {
                if pan.allowedTouchTypes != original.allowedTouchTypes {
                    pan.allowedTouchTypes = original.allowedTouchTypes
                }
                if pan.minimumNumberOfTouches != original.minimumNumberOfTouches {
                    pan.minimumNumberOfTouches = original.minimumNumberOfTouches
                }
                if pan.maximumNumberOfTouches != original.maximumNumberOfTouches {
                    pan.maximumNumberOfTouches = original.maximumNumberOfTouches
                }
                originalPDFPanConfigurations.removeObject(forKey: pan)
            }
        }
        #endif
    }
}
