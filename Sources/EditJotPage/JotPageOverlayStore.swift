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
        cached.setObject(overlay, forKey: page)
        canvases[index] = canvas
        overlays[index] = overlay
        indices[ObjectIdentifier(canvas)] = index
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
        return true
    }

    func reset() {
        for canvas in canvases.values {
            canvas.delegate = nil
            canvas.isRulerActive = false
        }
        overlays.removeAll()
        canvases.removeAll()
        indices.removeAll()
        cached.removeAllObjects()
    }
}
