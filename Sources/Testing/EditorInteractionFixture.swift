#if DEBUG
import UIKit
import PDFKit
@preconcurrency import PencilKit

/// Deterministic local document for UI input tests. Enabled only by the test
/// runner's launch environment; no account or remote document is used.
@MainActor
enum EditorInteractionFixture {
    static var tool: String? {
        let value = ProcessInfo.processInfo.environment["JOTTRE_INTERACTION_TEST_TOOL"]
        return ["pen", "lasso"].contains(value ?? "") ? value : nil
    }

    static func publish(canvas: PKCanvasView, index: Int, pdfView: PDFView, host: UIView) {
        guard tool != nil else { return }
        let identifier = "editor.page.\(index)"
        let label = host.subviews.first { $0.accessibilityIdentifier == identifier } as? EditorInteractionProbe ?? EditorInteractionProbe()
        if label.superview == nil {
            label.frame = CGRect(x: 100, y: 50 + index * 20, width: 120, height: 18)
            label.text = "UI test page \(index + 1)"
            label.font = .systemFont(ofSize: 10)
            label.isUserInteractionEnabled = false
            label.isAccessibilityElement = true
            label.accessibilityIdentifier = identifier
            host.addSubview(label)
        }
        label.makeValue = { [weak canvas, weak pdfView, weak host] in
            guard let canvas, let pdfView, let host, let page = pdfView.document?.page(at: index),
                let window = host.window else { return nil }
            let rect = pdfView.convert(pdfView.convert(page.bounds(for: .cropBox), from: page), to: window)
            let midX = canvas.drawing.strokes.isEmpty ? 0 : canvas.drawing.bounds.midX
            guard [rect.minX, rect.minY, rect.width, rect.height, midX].allSatisfy(\.isFinite),
                rect.width > 0, rect.height > 0 else { return nil }
            let info: [String: Any] = [
                "midX": midX,
                "strokes": canvas.drawing.strokes.count,
                "rect": [rect.minX, rect.minY, rect.width, rect.height],
                "tool": canvas.tool is PKLassoTool ? "lasso" : "pen",
                "firstResponder": canvas.isFirstResponder,
                "markup": pdfView.isInMarkupMode,
                "input": canvas.isDrawingEnabled,
                "drawingPolicy": canvas.drawingPolicy.rawValue,
                "drawingGesture": canvas.drawingGestureRecognizer.isEnabled,
                "offset": [canvas.contentOffset.x, canvas.contentOffset.y],
            ]
            if let data = try? JSONSerialization.data(withJSONObject: info), let value = String(data: data, encoding: .utf8)
            {
                return value
            }
            return nil
        }
    }

    static func makeDocument(using service: any JotFileServiceProtocol) throws -> JotFile.Info {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let pdf = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for index in 0..<2 {
                context.beginPage()
                UIColor.white.setFill()
                context.cgContext.fill(bounds)
                ("Selectable text page \(index + 1)" as NSString).draw(
                    at: CGPoint(x: 40, y: 40),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.black]
                )
            }
        }
        let strokes = (0..<2).map { index in
            let y = CGFloat(index) * (1600 + JotPageLayout.pageSpacing) + 600
            let points = [CGPoint(x: 360, y: y), CGPoint(x: 840, y: y)].enumerated().map { offset, point in
                PKStrokePoint(
                    location: point,
                    timeOffset: Double(offset) * 0.2,
                    size: CGSize(width: 12, height: 12),
                    opacity: 1,
                    force: 1,
                    azimuth: 0,
                    altitude: .pi / 2
                )
            }
            return PKStroke(
                ink: PKInk(.pen, color: .black),
                path: PKStrokePath(controlPoints: points, creationDate: .distantPast)
            )
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("interaction-fixture-" + UUID().uuidString + ".jot")
        let info = JotFile.Info(url: url, name: "Interaction Fixture", modificationDate: nil)
        try service.write(
            jotFile: JotFile(
                info: info,
                jot: Jot(
                    drawing: PKDrawing(strokes: tool == "lasso" ? [] : strokes).dataRepresentation(),
                    width: 1200,
                    pdfData: pdf,
                    strokePageIndices: tool == "lasso" ? [] : [0, 1]
                )
            )
        )
        return info
    }
}

@MainActor
private final class EditorInteractionProbe: UILabel {
    var makeValue: (() -> String?)?
    override var accessibilityValue: String? {
        get { makeValue?() }
        set { super.accessibilityValue = newValue }
    }
}
#endif
