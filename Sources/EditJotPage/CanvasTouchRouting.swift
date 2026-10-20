@preconcurrency import PencilKit
import UIKit

/// Separates PencilKit input from PDFKit document navigation.
@MainActor
enum CanvasTouchRouting {
    private static let originalPDFPanTouchTypes = NSMapTable<UIPanGestureRecognizer, NSArray>.weakToStrongObjects()

    static func usesPersistentResponder(isEditing: Bool, tool: any PKTool) -> Bool {
        isEditing && !(tool is PKLassoTool)
    }

    static func drawingPolicy(for _: PKTool) -> PKCanvasViewDrawingPolicy {
        // PencilKit owns native inking, erasing and lasso interactions. Fingers
        // stay available to PDFKit for document navigation and zoom gestures.
        .pencilOnly
    }

    static func shouldPassDirectTouchesThroughOverlay(rulerActive: Bool) -> Bool {
        !rulerActive
    }

    struct Configuration: Equatable, Sendable {
        let isFingerDrawingEnabled: Bool

        var documentPanMinimumNumberOfTouches: Int {
            isFingerDrawingEnabled ? 2 : 1
        }
    }

    static func configuration(
        isEditingEnabled: Bool,
        drawingPolicy: PKCanvasViewDrawingPolicy,
        isToolPickerVisible: Bool,
        prefersPencilOnlyDrawing: Bool
    ) -> Configuration {
        guard isEditingEnabled else { return Configuration(isFingerDrawingEnabled: false) }

        switch drawingPolicy {
        case .anyInput:
            return Configuration(isFingerDrawingEnabled: true)
        case .pencilOnly:
            return Configuration(isFingerDrawingEnabled: false)
        case .default:
            return Configuration(
                isFingerDrawingEnabled: isToolPickerVisible && !prefersPencilOnlyDrawing
            )
        @unknown default:
            return Configuration(isFingerDrawingEnabled: false)
        }
    }

    /// PDFKit sees direct touches only while PencilKit handles Apple Pencil.
    /// Recognizers are restored to their original input types on editor exit.
    static func apply(
        _ configuration: Configuration,
        to panGestureRecognizers: [UIPanGestureRecognizer],
        pencilInputHasPriority: Bool = false
    ) {
        #if !targetEnvironment(macCatalyst)
        for pan in panGestureRecognizers {
            let minimum = configuration.documentPanMinimumNumberOfTouches
            if pan.maximumNumberOfTouches < minimum { pan.maximumNumberOfTouches = minimum }
            if pan.minimumNumberOfTouches != minimum { pan.minimumNumberOfTouches = minimum }

            if pencilInputHasPriority {
                if originalPDFPanTouchTypes.object(forKey: pan) == nil {
                    originalPDFPanTouchTypes.setObject(pan.allowedTouchTypes as NSArray, forKey: pan)
                }
                let directTouch = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                if pan.allowedTouchTypes != directTouch { pan.allowedTouchTypes = directTouch }
            } else if let original = originalPDFPanTouchTypes.object(forKey: pan) as? [NSNumber] {
                pan.allowedTouchTypes = original
                originalPDFPanTouchTypes.removeObject(forKey: pan)
            }
        }
        #endif
    }
}
