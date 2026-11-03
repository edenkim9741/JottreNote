#if DEBUG
import UIKit
import PDFKit
@preconcurrency import PencilKit

/// Deterministic local document for UI input tests. Enabled only by the test
/// runner's launch environment; no account or remote document is used.
@MainActor
enum EditorInteractionFixture {
    static var pickerRulerActive = false

    static var tool: String? {
        let value = ProcessInfo.processInfo.environment["JOTTRE_INTERACTION_TEST_TOOL"]
        return ["pen", "lasso", "blank-pen", "scribble-undo"].contains(value ?? "") ? value : nil
    }

    private(set) static var scribbleRecognitionCount = 0
    private(set) static var scribbleEraseApplicationCount = 0
    private(set) static var undoTrace: [String] = []
    private(set) static var fixtureUndoActionCount = 0
    private(set) static var fixtureRedoActionCount = 0
    private(set) static var lastFixtureUndoState = "none"

    static func didRecognizeScribble() {
        guard tool == "scribble-undo" else { return }
        scribbleRecognitionCount += 1
        print("[InkUndo UIFixture] Scribble recognized count=\(scribbleRecognitionCount)")
    }

    static func didApplyScribbleErase() {
        guard tool == "scribble-undo" else { return }
        scribbleEraseApplicationCount += 1
        print("[InkUndo UIFixture] Scribble Erase applied count=\(scribbleEraseApplicationCount)")
    }

    static func recordUndoTrace(_ value: String) {
        guard tool == "scribble-undo" else { return }
        undoTrace.append(value)
        if undoTrace.count > 120 { undoTrace.removeFirst(undoTrace.count - 120) }
    }

    static func publish(canvas: PKCanvasView, index: Int, pdfView: PDFView, host: UIView) {
        guard tool != nil else { return }
        if tool == "scribble-undo" {
            installUndoButton(in: host, identifier: "editor.test.undo", title: "Undo") { [weak canvas] in
                guard let canvas, let manager = canvas.undoManager else { return }
                fixtureUndoActionCount += 1
                lastFixtureUndoState = "before canUndo=\(manager.canUndo) canRedo=\(manager.canRedo) group=\(manager.groupingLevel) undoAction=\(manager.undoActionName) redoAction=\(manager.redoActionName) seeds=\(canvas.drawing.strokes.map(\.randomSeed))"
                print("[InkUndo UIFixture] Undo canvas=\(ObjectIdentifier(canvas)) manager=\(ObjectIdentifier(manager)) group=\(manager.groupingLevel) groupsByEvent=\(manager.groupsByEvent) canUndo=\(manager.canUndo) canRedo=\(manager.canRedo) undoAction=\(manager.undoActionName) redoAction=\(manager.redoActionName) isUndoing=\(manager.isUndoing) isRedoing=\(manager.isRedoing) seeds=\(canvas.drawing.strokes.map(\.randomSeed))")
                manager.undo()
                lastFixtureUndoState += " after canUndo=\(manager.canUndo) canRedo=\(manager.canRedo) group=\(manager.groupingLevel) undoAction=\(manager.undoActionName) redoAction=\(manager.redoActionName) isUndoing=\(manager.isUndoing) isRedoing=\(manager.isRedoing) seeds=\(canvas.drawing.strokes.map(\.randomSeed))"
                print("[InkUndo UIFixture] Undo completed seeds=\(canvas.drawing.strokes.map(\.randomSeed)) canUndo=\(manager.canUndo) canRedo=\(manager.canRedo)")
            }
            installUndoButton(in: host, identifier: "editor.test.redo", title: "Redo") { [weak canvas] in
                guard let canvas, let manager = canvas.undoManager else { return }
                fixtureRedoActionCount += 1
                print("[InkUndo UIFixture] Redo canvas=\(ObjectIdentifier(canvas)) manager=\(ObjectIdentifier(manager)) group=\(manager.groupingLevel) groupsByEvent=\(manager.groupsByEvent) canUndo=\(manager.canUndo) canRedo=\(manager.canRedo) isUndoing=\(manager.isUndoing) isRedoing=\(manager.isRedoing) seeds=\(canvas.drawing.strokes.map(\.randomSeed))")
                manager.redo()
                print("[InkUndo UIFixture] Redo completed seeds=\(canvas.drawing.strokes.map(\.randomSeed)) canUndo=\(manager.canUndo) canRedo=\(manager.canRedo)")
            }
        }
        if !host.subviews.contains(where: { $0.accessibilityIdentifier == "editor.test.nextPage" }) {
            let nextPageButton = UIButton(type: .system)
            nextPageButton.frame = CGRect(x: 12, y: 112, width: 44, height: 36)
            nextPageButton.setImage(UIImage(systemName: "arrow.down.page"), for: .normal)
            nextPageButton.accessibilityLabel = "Next test page"
            nextPageButton.accessibilityIdentifier = "editor.test.nextPage"
            nextPageButton.addAction(UIAction { [weak pdfView] _ in
                guard let pdfView, let document = pdfView.document,
                    let currentPage = pdfView.currentPage else { return }
                let currentIndex = document.index(for: currentPage)
                guard currentIndex != NSNotFound, currentIndex + 1 < document.pageCount,
                    let nextPage = document.page(at: currentIndex + 1) else { return }
                pdfView.go(to: nextPage)
            }, for: .touchUpInside)
            host.addSubview(nextPageButton)
        }
        let identifier = "editor.page.\(index)"
        let label = host.subviews.first { $0.accessibilityIdentifier == identifier } as? EditorInteractionProbe ?? EditorInteractionProbe()
        if label.superview == nil {
            label.frame = CGRect(x: 100, y: 50 + index * 20, width: 120, height: 18)
            label.text = "UI test page \(index + 1)"
            label.font = .systemFont(ofSize: 10)
            label.textColor = .clear
            label.isUserInteractionEnabled = false
            label.isAccessibilityElement = true
            label.accessibilityIdentifier = identifier
            host.addSubview(label)
        }
        label.makeValue = { [weak canvas, weak pdfView, weak host] in
            guard let canvas, let pdfView, let host, let page = pdfView.document?.page(at: index),
                let window = host.window else { return nil }
            let rect = pdfView.convert(pdfView.convert(page.bounds(for: .cropBox), from: page), to: window)
            let viewportRect = pdfView.convert(pdfView.bounds.inset(by: pdfView.safeAreaInsets), to: window)
            let canvasRect = canvas.convert(canvas.bounds, to: window)
            let currentPageIndex = pdfView.document.flatMap { document in
                pdfView.currentPage.map { document.index(for: $0) }
            } ?? NSNotFound
            label.frame = host.convert(rect, from: window)
            let canvasMenuInteractions = editMenuInteractionDescriptions(in: canvas)
            let pdfMenuInteractions = editMenuInteractionDescriptions(in: pdfView)
            let midX = canvas.drawing.strokes.isEmpty ? 0 : canvas.drawing.bounds.midX
            let toolName: String
            if canvas.tool is PKLassoTool {
                toolName = "lasso"
            } else if canvas.tool is PKEraserTool {
                toolName = "eraser"
            } else {
                toolName = "pen"
            }
            guard [rect.minX, rect.minY, rect.width, rect.height,
                   viewportRect.minX, viewportRect.minY, viewportRect.width, viewportRect.height,
                   canvasRect.minX, canvasRect.minY, canvasRect.width, canvasRect.height,
                   midX, pdfView.scaleFactor].allSatisfy(\.isFinite),
                rect.width > 0, rect.height > 0 else { return nil }
            let info: [String: Any] = [
                "midX": midX,
                "strokes": canvas.drawing.strokes.count,
                "strokeSeeds": canvas.drawing.strokes.map(\.randomSeed),
                "canvasIdentity": String(describing: ObjectIdentifier(canvas)),
                "undoManagerIdentity": canvas.undoManager.map { String(describing: ObjectIdentifier($0)) } ?? "nil",
                "groupingLevel": canvas.undoManager?.groupingLevel ?? -1,
                "groupsByEvent": canvas.undoManager?.groupsByEvent ?? false,
                "canUndo": canvas.undoManager?.canUndo ?? false,
                "canRedo": canvas.undoManager?.canRedo ?? false,
                "isUndoing": canvas.undoManager?.isUndoing ?? false,
                "isRedoing": canvas.undoManager?.isRedoing ?? false,
                "undoActionName": canvas.undoManager?.undoActionName ?? "",
                "redoActionName": canvas.undoManager?.redoActionName ?? "",
                "scribbleRecognitionCount": scribbleRecognitionCount,
                "scribbleEraseApplicationCount": scribbleEraseApplicationCount,
                "undoTrace": undoTrace,
                "fixtureUndoActionCount": fixtureUndoActionCount,
                "fixtureRedoActionCount": fixtureRedoActionCount,
                "lastFixtureUndoState": lastFixtureUndoState,
                "rect": [rect.minX, rect.minY, rect.width, rect.height],
                "viewportRect": [viewportRect.minX, viewportRect.minY, viewportRect.width, viewportRect.height],
                "canvasRect": [canvasRect.minX, canvasRect.minY, canvasRect.width, canvasRect.height],
                "scaleFactor": pdfView.scaleFactor,
                "currentPageIndex": currentPageIndex,
                "tool": toolName,
                "firstResponder": canvas.isFirstResponder,
                "markup": pdfView.isInMarkupMode,
                "input": canvas.isDrawingEnabled,
                "canvasRulerActive": canvas.isRulerActive,
                "pickerRulerActive": pickerRulerActive,
                "drawingPolicy": canvas.drawingPolicy.rawValue,
                "drawingGesture": canvas.drawingGestureRecognizer.isEnabled,
                "offset": [canvas.contentOffset.x, canvas.contentOffset.y],
                "canvasEditMenuInteractions": canvasMenuInteractions,
                "pdfEditMenuInteractions": pdfMenuInteractions,
                "blankNoteFixture": tool == "blank-pen",
            ]
            if let data = try? JSONSerialization.data(withJSONObject: info), let value = String(data: data, encoding: .utf8)
            {
                return value
            }
            return nil
        }
    }

    private static func editMenuInteractionDescriptions(in root: UIView) -> [String] {
        func collect(_ view: UIView) -> [String] {
            let own = view.interactions.compactMap { interaction -> String? in
                guard let menu = interaction as? UIEditMenuInteraction else { return nil }
                return "\(String(describing: type(of: view))):\(menu.delegate.map { String(describing: type(of: $0)) } ?? "system")"
            }
            return own + view.subviews.flatMap(collect)
        }
        return collect(root)
    }

    static func makeDocument(using service: any JotFileServiceProtocol) throws -> JotFile.Info {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let pageCount = tool == "scribble-undo" ? 1 : 2
        let pdf = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for index in 0..<pageCount {
                context.beginPage()
                UIColor.white.setFill()
                context.cgContext.fill(bounds)
                if tool != "scribble-undo" {
                    ("Selectable text page \(index + 1)" as NSString).draw(
                        at: CGPoint(x: 40, y: 40),
                        withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.black]
                    )
                }
            }
        }
        let initialStrokeCount = tool == "blank-pen" ? 1 : (tool == "scribble-undo" ? 0 : 2)
        let strokes = (0..<initialStrokeCount).map { index in
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
        let isBlankNote = tool == "blank-pen"
        try service.write(
            jotFile: JotFile(
                info: info,
            jot: Jot(
                    drawing: PKDrawing(strokes: tool == "lasso" || tool == "scribble-undo" ? [] : strokes).dataRepresentation(),
                    width: 1200,
                    pdfData: isBlankNote ? nil : pdf,
                    strokePageIndices: tool == "lasso" || tool == "scribble-undo" ? [] : (isBlankNote ? [0] : [0, 1])
                )
            )
        )
        return info
    }

    private static func installUndoButton(
        in host: UIView,
        identifier: String,
        title: String,
        action: @escaping () -> Void
    ) {
        guard !host.subviews.contains(where: { $0.accessibilityIdentifier == identifier }) else { return }
        let button = UIButton(type: .system)
        button.frame = CGRect(x: 12, y: identifier.hasSuffix("undo") ? 150 : 194, width: 76, height: 36)
        button.setTitle(title, for: .normal)
        button.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = title
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        host.addSubview(button)
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
