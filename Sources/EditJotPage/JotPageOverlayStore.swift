import PDFKit
import UIKit

/// Holds displayed overlays only. PDFKit owns any offscreen reuse; our weak
/// lookup never keeps PencilKit textures alive after PDFKit releases a page.
@MainActor
final class JotPageOverlayStore {
    private let cached = NSMapTable<PDFPage, JotPDFPageCanvasOverlay>.weakToWeakObjects()
    private(set) var overlays: [Int: JotPDFPageCanvasOverlay] = [:]
    private(set) var canvases: [Int: JotCanvasView] = [:]
    private(set) var indices: [ObjectIdentifier: Int] = [:]

    func overlay(for page: PDFPage) -> JotPDFPageCanvasOverlay? { cached.object(forKey: page) }

    func register(_ overlay: JotPDFPageCanvasOverlay, page: PDFPage, index: Int) {
        guard let canvas = overlay.canvas as? JotCanvasView else { return }
        let isAlreadyRegistered = overlays[index] === overlay
        cached.setObject(overlay, forKey: page)
        canvases[index] = canvas
        overlays[index] = overlay
        indices[ObjectIdentifier(canvas)] = index
        overlay.setDiagnosticsPage(page, index: index)
        guard !isAlreadyRegistered else { return }
        let details: [String: Any] = [
            "pageIndex": index,
            "pageRotation": page.rotation,
            "cropBox": [page.bounds(for: .cropBox).minX, page.bounds(for: .cropBox).minY,
                        page.bounds(for: .cropBox).width, page.bounds(for: .cropBox).height],
            "pageDimensions": [overlay.bounds.width, overlay.bounds.height],
            "strokeCount": canvas.drawing.strokes.count,
            "canvasZoomScale": canvas.zoomScale,
            "contentSize": [canvas.contentSize.width, canvas.contentSize.height],
            "canvasBounds": [canvas.bounds.width, canvas.bounds.height],
            "activeCanvasCount": canvases.count,
            "activeOverlayCount": overlays.count
        ]
        JottreDiagnostics.shared.updateCanvasMemoryContext(details)
        JottreDiagnostics.shared.record("canvas.overlayCreated", details: details)
        JottreDiagnostics.shared.sampleMemoryNow(for: "canvas.memorySample", details: details)
    }

    @discardableResult
    func remove(_ overlay: JotPDFPageCanvasOverlay, page: PDFPage) -> Bool {
        guard cached.object(forKey: page) === overlay,
            let canvas = overlay.canvas as? JotCanvasView,
            let index = indices[ObjectIdentifier(canvas)],
            overlays[index] === overlay
        else { return false }
        indices.removeValue(forKey: ObjectIdentifier(canvas))
        canvases.removeValue(forKey: index)
        overlays.removeValue(forKey: index)
        let details: [String: Any] = [
            "pageIndex": index,
            "pageRotation": page.rotation,
            "cropBox": [page.bounds(for: .cropBox).minX, page.bounds(for: .cropBox).minY,
                        page.bounds(for: .cropBox).width, page.bounds(for: .cropBox).height],
            "pageDimensions": [overlay.bounds.width, overlay.bounds.height],
            "strokeCount": canvas.drawing.strokes.count,
            "canvasZoomScale": canvas.zoomScale,
            "contentSize": [canvas.contentSize.width, canvas.contentSize.height],
            "canvasBounds": [canvas.bounds.width, canvas.bounds.height],
            "activeCanvasCount": canvases.count,
            "activeOverlayCount": overlays.count
        ]
        JottreDiagnostics.shared.updateCanvasMemoryContext(details)
        JottreDiagnostics.shared.record("canvas.overlayRemoved", details: details)
        JottreDiagnostics.shared.sampleMemoryNow(for: "canvas.memorySample", details: details)
        return true
    }

    func reset() {
        let removedOverlays = overlays
        for canvas in canvases.values {
            canvas.delegate = nil
        }
        overlays.removeAll()
        canvases.removeAll()
        indices.removeAll()
        cached.removeAllObjects()
        guard !removedOverlays.isEmpty else { return }
        var latestDetails: [String: Any] = ["activeCanvasCount": 0, "activeOverlayCount": 0]
        for (pageIndex, overlay) in removedOverlays {
            let details: [String: Any] = [
                "pageIndex": pageIndex,
                "pageRotation": overlay.diagnosticsPageRotation,
                "cropBox": [overlay.diagnosticsCropBox.minX, overlay.diagnosticsCropBox.minY,
                            overlay.diagnosticsCropBox.width, overlay.diagnosticsCropBox.height],
                "pageDimensions": [overlay.bounds.width, overlay.bounds.height],
                "strokeCount": overlay.canvas.drawing.strokes.count,
                "canvasZoomScale": overlay.canvas.zoomScale,
                "contentSize": [overlay.canvas.contentSize.width, overlay.canvas.contentSize.height],
                "canvasBounds": [overlay.canvas.bounds.width, overlay.canvas.bounds.height],
                "activeCanvasCount": 0,
                "activeOverlayCount": 0,
                "reason": "reset"
            ]
            latestDetails = details
            JottreDiagnostics.shared.record("canvas.overlayRemoved", details: details)
        }
        JottreDiagnostics.shared.updateCanvasMemoryContext(latestDetails)
        JottreDiagnostics.shared.sampleMemoryNow(for: "canvas.memorySample", details: latestDetails)
    }
}
