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
        return ["pen", "lasso", "blank-pen", "scribble-undo", "zoom-memory"].contains(value ?? "") ? value : nil
    }

    private static var rotatesFixturePage: Bool {
        ProcessInfo.processInfo.environment["JOTTRE_INTERACTION_TEST_ROTATED_CROP"] == "1"
    }

    private(set) static var scribbleRecognitionCount = 0
    private(set) static var scribbleEraseApplicationCount = 0
    private(set) static var undoTrace: [String] = []
    private(set) static var fixtureUndoActionCount = 0
    private(set) static var fixtureRedoActionCount = 0
    private(set) static var customNoDrawingUndoCount = 0
    private(set) static var lastFixtureUndoState = "none"
    private static var zoomBaseScales: [ObjectIdentifier: CGFloat] = [:]
    private static var nextZoomStep = 0
    private static let zoomFactors: [CGFloat] = [1, 2, 4, 8, 16, 32, 64]
    private(set) static var fixturePDFSizeBytes = 0

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

    static func recordCustomNoDrawingUndo() {
        guard tool == "scribble-undo" else { return }
        customNoDrawingUndoCount += 1
    }

    static func publish(
        canvas: PKCanvasView,
        index: Int,
        pdfView: PDFView,
        host: UIView,
        drawingStateProvider: (() -> (committed: PKDrawing, model: PKDrawing))? = nil,
        activeCanvasCountsProvider: (() -> (canvases: Int, overlays: Int))? = nil,
        onProgrammaticMiddleRemoval: (() -> Void)? = nil,
        onDetachedProgrammaticMiddleRemoval: (() -> Void)? = nil,
        onCanvasOnlyMiddleRemoval: (() -> Void)? = nil
    ) {
        guard tool != nil else { return }
        installZoomControls(in: host, pdfView: pdfView)
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
            if let onProgrammaticMiddleRemoval {
                installUndoButton(in: host, identifier: "editor.test.removeMiddle", title: "Remove B") {
                    onProgrammaticMiddleRemoval()
                }
            }
            if let onDetachedProgrammaticMiddleRemoval {
                installUndoButton(in: host, identifier: "editor.test.removeMiddleDetached", title: "Remove B detached") {
                    onDetachedProgrammaticMiddleRemoval()
                }
            }
            if let onCanvasOnlyMiddleRemoval {
                installUndoButton(in: host, identifier: "editor.test.removeMiddleCanvasOnly", title: "Remove B Canvas Only") {
                    onCanvasOnlyMiddleRemoval()
                }
            }
            installUndoButton(in: host, identifier: "editor.test.registerNoopUndo", title: "Register No-op Undo") { [weak canvas] in
                guard let canvas, let manager = canvas.undoManager else { return }
                for index in 0..<3 {
                    manager.beginUndoGrouping()
                    manager.registerUndo(withTarget: canvas) { _ in
                        EditorInteractionFixture.recordCustomNoDrawingUndo()
                        manager.registerUndo(withTarget: canvas) { _ in
                            EditorInteractionFixture.recordCustomNoDrawingUndo()
                        }
                    }
                    manager.setActionName("No-op test \(index)")
                    manager.endUndoGrouping()
                }
                recordUndoTrace("three custom no-drawing groups registered manager=\(ObjectIdentifier(manager)) canUndo=\(manager.canUndo) groupingLevel=\(manager.groupingLevel) groupsByEvent=\(manager.groupsByEvent)")
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
        label.makeValue = { [weak canvas, weak pdfView, weak host, drawingStateProvider] in
            guard let canvas, let pdfView, let host, let page = pdfView.document?.page(at: index),
                let window = host.window else { return nil }
            let rect = pdfView.convert(pdfView.convert(page.bounds(for: .cropBox), from: page), to: window)
            let viewportRect = pdfView.convert(pdfView.bounds.inset(by: pdfView.safeAreaInsets), to: window)
            let canvasRect = canvas.convert(canvas.bounds, to: window)
            let currentPageIndex = pdfView.document.flatMap { document in
                pdfView.currentPage.map { document.index(for: $0) }
            } ?? NSNotFound
            let overlay = canvas.superview?.superview as? JotPDFPageCanvasOverlay
            let lastStroke = canvas.drawing.strokes.last
            let strokeStart = lastStroke?.path.first?.location.applying(lastStroke?.transform ?? .identity) ?? .zero
            let strokeEnd = lastStroke?.path.last?.location.applying(lastStroke?.transform ?? .identity) ?? .zero
            let diagnosticCanvas = canvas as? JotCanvasView
            let touchStartWindow = diagnosticCanvas?.diagnosticTouchStartInWindow
            let touchEndWindow = diagnosticCanvas?.diagnosticTouchEndInWindow
            let activeCanvasCounts = activeCanvasCountsProvider?() ?? (canvases: 1, overlays: 1)
            let strokeStartWindow: CGPoint? = overlay.flatMap { overlay in
                guard overlay.drawingSize.width > 0, overlay.drawingSize.height > 0 else { return nil }
                return overlay.convert(
                    CGPoint(
                        x: strokeStart.x * overlay.bounds.width / overlay.drawingSize.width,
                        y: strokeStart.y * overlay.bounds.height / overlay.drawingSize.height
                    ),
                    to: window
                )
            }
            let strokeEndWindow: CGPoint? = overlay.flatMap { overlay in
                guard overlay.drawingSize.width > 0, overlay.drawingSize.height > 0 else { return nil }
                return overlay.convert(
                    CGPoint(
                        x: strokeEnd.x * overlay.bounds.width / overlay.drawingSize.width,
                        y: strokeEnd.y * overlay.bounds.height / overlay.drawingSize.height
                    ),
                    to: window
                )
            }
            let startErrorPixels: CGFloat? = if let touchStartWindow, let strokeStartWindow {
                hypot(strokeStartWindow.x - touchStartWindow.x, strokeStartWindow.y - touchStartWindow.y)
                    * window.screen.scale
            } else {
                nil
            }
            label.frame = host.convert(rect, from: window)
            let canvasMenuInteractions = editMenuInteractionDescriptions(in: canvas)
            let pdfMenuInteractions = editMenuInteractionDescriptions(in: pdfView)
            let synchronizedDrawings = drawingStateProvider?()
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
            var info: [String: Any] = [
                "midX": midX,
                "strokes": canvas.drawing.strokes.count,
                "strokeSeeds": canvas.drawing.strokes.map(\.randomSeed),
                "committedStrokeSeeds": synchronizedDrawings?.committed.strokes.map(\.randomSeed) ?? [],
                "viewModelStrokeSeeds": synchronizedDrawings?.model.strokes.map(\.randomSeed) ?? [],
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
                "customNoDrawingUndoCount": customNoDrawingUndoCount,
                "lastFixtureUndoState": lastFixtureUndoState,
                "rect": [rect.minX, rect.minY, rect.width, rect.height],
                "viewportRect": [viewportRect.minX, viewportRect.minY, viewportRect.width, viewportRect.height],
                "canvasRect": [canvasRect.minX, canvasRect.minY, canvasRect.width, canvasRect.height],
                "scaleFactor": pdfView.scaleFactor,
                "fitScaleFactor": zoomBaseScales[ObjectIdentifier(pdfView)] ?? pdfView.scaleFactor,
                "canvasZoom": canvas.zoomScale,
                "minimumCanvasZoom": canvas.minimumZoomScale,
                "maximumCanvasZoom": canvas.maximumZoomScale,
                "canvasBounds": [canvas.bounds.width, canvas.bounds.height],
                "canvasContentScaleFactor": canvas.contentScaleFactor,
                "contentSize": [canvas.contentSize.width, canvas.contentSize.height],
                "contentOffset": [canvas.contentOffset.x, canvas.contentOffset.y],
                "overlayBounds": [overlay?.bounds.width ?? 0, overlay?.bounds.height ?? 0],
                "drawingSize": [overlay?.drawingSize.width ?? 0, overlay?.drawingSize.height ?? 0],
                "measuredDisplayScale": overlay?.displayScale ?? 0,
                "viewportHostTransform": [overlay?.viewportHostTransform.a ?? 0, overlay?.viewportHostTransform.d ?? 0],
                "pageRotation": page.rotation,
                "cropBox": rectArray(page.bounds(for: .cropBox)),
                "lastStrokeStart": [strokeStart.x, strokeStart.y],
                "lastStrokeEnd": [strokeEnd.x, strokeEnd.y],
                "touchStartWindow": touchStartWindow.map { [$0.x, $0.y] } ?? [],
                "touchEndWindow": touchEndWindow.map { [$0.x, $0.y] } ?? [],
                "lastStrokeStartWindow": strokeStartWindow.map { [$0.x, $0.y] } ?? [],
                "lastStrokeEndWindow": strokeEndWindow.map { [$0.x, $0.y] } ?? [],
                "lastStrokeStartErrorPixels": startErrorPixels ?? -1,
                "screenScale": window.screen.scale,
                "physicalFootprintBytes": JottreDiagnostics.currentFootprintBytesForTesting() ?? 0,
                "pdfPageCount": pdfView.document?.pageCount ?? 0,
                "pdfDataBytes": fixturePDFSizeBytes,
                "activeCanvasCount": activeCanvasCounts.canvases,
                "activeOverlayCount": activeCanvasCounts.overlays,
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
#if DEBUG
            info["geometryExperimentMode"] = JotPDFPageCanvasOverlay.geometryExperimentMode.rawValue
#endif
            if let data = try? JSONSerialization.data(withJSONObject: info), let value = String(data: data, encoding: .utf8)
            {
                return value
            }
            return nil
        }
    }

    private static func rectArray(_ rect: CGRect) -> [CGFloat] {
        [rect.minX, rect.minY, rect.width, rect.height]
    }

    private static func installZoomControls(in host: UIView, pdfView: PDFView) {
        guard let window = host.window,
              !window.subviews.contains(where: { $0.accessibilityIdentifier == "editor.test.zoomFactor" }) else { return }
        let viewID = ObjectIdentifier(pdfView)
        zoomBaseScales[viewID] = max(pdfView.scaleFactor, 0.01)
        nextZoomStep = 0
        let button = UIButton(type: .system)
        button.frame = host.convert(
            CGRect(x: max(12, host.bounds.width - 120), y: 150, width: 108, height: 36),
            to: window
        )
        button.setTitle("Next zoom", for: .normal)
        button.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
        button.accessibilityLabel = "Next zoom factor"
        button.accessibilityIdentifier = "editor.test.zoomFactor"
        button.addAction(UIAction { _ in
            let factor = zoomFactors[nextZoomStep % zoomFactors.count]
            nextZoomStep += 1
            pdfView.autoScales = false
            let fitScale = zoomBaseScales[viewID] ?? max(pdfView.scaleFactor, 0.01)
            pdfView.minScaleFactor = min(pdfView.minScaleFactor, fitScale)
            pdfView.maxScaleFactor = max(pdfView.maxScaleFactor, fitScale * 64)
            pdfView.scaleFactor = fitScale * factor
            pdfView.setNeedsLayout()
            pdfView.layoutIfNeeded()
        }, for: .touchUpInside)
        window.addSubview(button)

        let experimentButton = UIButton(type: .system)
        experimentButton.frame = host.convert(
            CGRect(x: max(12, host.bounds.width - 120), y: 194, width: 108, height: 36),
            to: window
        )
        experimentButton.setTitle("Geometry mode", for: .normal)
        experimentButton.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
        experimentButton.accessibilityLabel = "Next canvas geometry experiment"
        experimentButton.accessibilityIdentifier = "editor.test.geometryExperiment"
        experimentButton.addAction(UIAction { _ in
            Task { @MainActor in
                let modes = JotCanvasGeometryExperimentMode.allCases
                let next = (JotPDFPageCanvasOverlay.geometryExperimentMode.rawValue + 1) % modes.count
                JotPDFPageCanvasOverlay.geometryExperimentMode = modes[next]
                @MainActor func refresh(_ view: UIView) {
                    if let overlay = view as? JotPDFPageCanvasOverlay {
                        overlay.configure(in: pdfView, pdfScaleFactor: pdfView.scaleFactor)
                        overlay.setNeedsLayout()
                        overlay.layoutIfNeeded()
                        return
                    }
                    for child in view.subviews { refresh(child) }
                }
                refresh(pdfView)
            }
        }, for: .touchUpInside)
        window.addSubview(experimentButton)
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
        let pageCount = tool == "scribble-undo" ? 1 : (tool == "zoom-memory" ? 3 : 2)
        let sourcePDF: Data
        if tool == "zoom-memory" {
            let image = makeMemoryFixtureImage()
            sourcePDF = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
                for index in 0..<pageCount {
                    context.beginPage()
                    if let cgImage = image.cgImage {
                        context.cgContext.draw(cgImage, in: bounds)
                    }
                    ("Memory fixture page \(index + 1)" as NSString).draw(
                        at: CGPoint(x: 40, y: 40),
                        withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.black]
                    )
                }
            }
        } else {
            sourcePDF = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
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
        }
        let pdf: Data
        if rotatesFixturePage,
           let document = PDFDocument(data: sourcePDF),
           let page = document.page(at: 0) {
            page.setBounds(CGRect(x: 40, y: 60, width: 500, height: 700), for: .cropBox)
            page.rotation = 90
            pdf = document.dataRepresentation() ?? sourcePDF
        } else {
            pdf = sourcePDF
        }
        fixturePDFSizeBytes = pdf.count
        let initialStrokeCount = tool == "blank-pen" ? 1
            : (tool == "scribble-undo" ? 0 : (tool == "zoom-memory" ? 416 : 2))
        let strokeEntries: [(stroke: PKStroke, pageIndex: Int)] = (0..<initialStrokeCount).map { index in
            let pageIndex = tool == "zoom-memory" ? index % 3 : index
            let row = tool == "zoom-memory" ? index / 3 : index
            let y = CGFloat(pageIndex) * (1600 + JotPageLayout.pageSpacing)
                + (tool == "zoom-memory" ? CGFloat(row % 130) * 11 + 80 : 600)
            let x = tool == "zoom-memory" ? CGFloat((row * 37) % 700) + 180 : 360
            let points: [PKStrokePoint]
            if tool == "zoom-memory" {
                points = (0..<24).map { pointIndex in
                    let t = CGFloat(pointIndex) / 23
                    let wave = sin(t * .pi * 4) * 20
                    return PKStrokePoint(
                        location: CGPoint(x: x + t * 420, y: y + wave),
                        timeOffset: Double(pointIndex) * 0.01,
                        size: CGSize(width: 7, height: 7),
                        opacity: 1,
                        force: 0.7,
                        azimuth: 0,
                        altitude: .pi / 2
                    )
                }
            } else {
                points = [CGPoint(x: 360, y: y), CGPoint(x: 840, y: y)].enumerated().map { offset, point in
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
            }
            return (
                PKStroke(
                    ink: PKInk(.pen, color: .black),
                    path: PKStrokePath(controlPoints: points, creationDate: .distantPast)
                ),
                pageIndex
            )
        }
        let strokes = strokeEntries.map(\.stroke)
        let strokePageIndices = strokeEntries.map(\.pageIndex)
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
                    strokePageIndices: tool == "lasso" || tool == "scribble-undo" ? [] : strokePageIndices
                )
            )
        )
        return info
    }

    private static func makeMemoryFixtureImage() -> UIImage {
        let size = CGSize(width: 1_800, height: 2_400)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            var random = UInt32(0x9741_2026)
            for _ in 0..<6_000 {
                random = random &* 1_664_525 &+ 1_013_904_223
                let x = CGFloat(random % UInt32(size.width))
                random = random &* 1_664_525 &+ 1_013_904_223
                let y = CGFloat(random % UInt32(size.height))
                random = random &* 1_664_525 &+ 1_013_904_223
                let diameter = CGFloat(random % 28) + 4
                let red = CGFloat((random >> 16) & 0xFF) / 255
                let green = CGFloat((random >> 8) & 0xFF) / 255
                let blue = CGFloat(random & 0xFF) / 255
                UIColor(red: red, green: green, blue: blue, alpha: 1).setFill()
                context.cgContext.fillEllipse(in: CGRect(x: x, y: y, width: diameter, height: diameter))
            }
        }
    }

    private static func installUndoButton(
        in host: UIView,
        identifier: String,
        title: String,
        action: @escaping () -> Void
    ) {
        guard !host.subviews.contains(where: { $0.accessibilityIdentifier == identifier }) else { return }
        let button = UIButton(type: .system)
        let top: CGFloat = identifier.hasSuffix("undo") ? 150
            : (identifier.hasSuffix("redo") ? 194
                : (identifier.contains("registerNoop") ? 326
                    : (identifier.contains("CanvasOnly") ? 370
                        : (identifier.hasSuffix("Detached") ? 282 : 238))))
        let left = identifier.contains("registerNoop") ? max(12, host.bounds.width - 88) : 12
        button.frame = CGRect(x: left, y: top, width: 76, height: 36)
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
