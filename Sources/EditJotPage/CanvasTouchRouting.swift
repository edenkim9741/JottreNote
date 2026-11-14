@preconcurrency import PencilKit
import UIKit

/// Separates PencilKit input from PDFKit document navigation.
@MainActor
enum CanvasTouchRouting {
    @MainActor
    private final class OriginalPDFPanConfiguration: NSObject {
        let allowedTouchTypes: [NSNumber]

        init(pan: UIPanGestureRecognizer) {
            allowedTouchTypes = pan.allowedTouchTypes
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

    /// PencilKit owns Pencil input. PDFKit's document pan always accepts direct
    /// touches, regardless of the selected PencilKit tool or picker state.
    /// Restore the recognizer's original touch types when editing ends.
    static func apply(
        to panGestureRecognizers: [UIPanGestureRecognizer],
        pencilInputHasPriority: Bool = false
    ) {
        #if !targetEnvironment(macCatalyst)
        for pan in panGestureRecognizers {
            if pencilInputHasPriority {
                if originalPDFPanConfigurations.object(forKey: pan) == nil {
                    originalPDFPanConfigurations.setObject(OriginalPDFPanConfiguration(pan: pan), forKey: pan)
                }
                let directTouch = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                if pan.allowedTouchTypes != directTouch { pan.allowedTouchTypes = directTouch }
            } else if let original = originalPDFPanConfigurations.object(forKey: pan) {
                if pan.allowedTouchTypes != original.allowedTouchTypes {
                    pan.allowedTouchTypes = original.allowedTouchTypes
                }
                originalPDFPanConfigurations.removeObject(forKey: pan)
            }
        }
        #endif
    }
}
