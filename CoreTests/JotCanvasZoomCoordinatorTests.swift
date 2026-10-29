import PDFKit
import UIKit
import XCTest

@testable import Jottre

@MainActor
final class JotCanvasZoomCoordinatorTests: XCTestCase {
    func testPortraitPageAlternatesWidthFitAndHeightFitScales() throws {
        let scales = try XCTUnwrap(
            JotCanvasZoomCoordinator.pageFitScales(
                pageSize: CGSize(width: 612, height: 792),
                viewportSize: CGSize(width: 1_024, height: 700)
            )
        )

        XCTAssertEqual(scales.shortSide, 1_024.0 / 612.0, accuracy: 0.0001)
        XCTAssertEqual(scales.longSide, 700.0 / 792.0, accuracy: 0.0001)
        XCTAssertEqual(JotCanvasZoomCoordinator.PageFitMode.shortSide.next, .longSide)
        XCTAssertEqual(JotCanvasZoomCoordinator.PageFitMode.longSide.next, .shortSide)
    }

    func testLandscapeAndRotatedPagesUseTheirDisplayedShortAndLongAxes() throws {
        let viewport = CGSize(width: 1_024, height: 700)
        let landscapeScales = try XCTUnwrap(
            JotCanvasZoomCoordinator.pageFitScales(
                pageSize: CGSize(width: 792, height: 612),
                viewportSize: viewport
            )
        )
        let rotatedPageSize = PDFAnnotationConverter.displaySize(
            for: CGRect(x: 12, y: 30, width: 612, height: 792),
            rotation: 90
        )
        let rotatedScales = try XCTUnwrap(
            JotCanvasZoomCoordinator.pageFitScales(pageSize: rotatedPageSize, viewportSize: viewport)
        )

        XCTAssertEqual(rotatedPageSize, CGSize(width: 792, height: 612))
        XCTAssertEqual(landscapeScales, rotatedScales)
        XCTAssertEqual(landscapeScales.shortSide, 700.0 / 612.0, accuracy: 0.0001)
        XCTAssertEqual(landscapeScales.longSide, 1_024.0 / 792.0, accuracy: 0.0001)
    }

    func testMixedPageDimensionsRecalculateIndependentFitScales() throws {
        let viewport = CGSize(width: 1_000, height: 720)
        let portrait = try XCTUnwrap(
            JotCanvasZoomCoordinator.pageFitScales(
                pageSize: CGSize(width: 500, height: 800),
                viewportSize: viewport
            )
        )
        let wideSlide = try XCTUnwrap(
            JotCanvasZoomCoordinator.pageFitScales(
                pageSize: CGSize(width: 1_200, height: 675),
                viewportSize: viewport
            )
        )

        XCTAssertNotEqual(portrait, wideSlide)
        XCTAssertEqual(portrait.shortSide, 2, accuracy: 0.0001)
        XCTAssertEqual(wideSlide.shortSide, 720.0 / 675.0, accuracy: 0.0001)
    }

    func testTargetsExpandScaleRangeAndRejectInvalidGeometry() throws {
        let targets = JotCanvasZoomCoordinator.PageFitScales(shortSide: 1.8, longSide: 0.72)
        let range = try XCTUnwrap(
            JotCanvasZoomCoordinator.expandedScaleRange(minimum: 1, maximum: 1.5, toInclude: targets)
        )

        XCTAssertEqual(range.minimum, 0.72, accuracy: 0.0001)
        XCTAssertEqual(range.maximum, 1.8, accuracy: 0.0001)
        XCTAssertNil(JotCanvasZoomCoordinator.pageFitScales(pageSize: .zero, viewportSize: CGSize(width: 100, height: 100)))
    }

    func testPageFitViewportKeepsSymmetricGuttersInsideActualViewport() throws {
        let actualViewport = CGRect(x: 12, y: 30, width: 1_000, height: 700)
        let fittedViewport = try XCTUnwrap(JotCanvasZoomCoordinator.pageFitViewport(actualViewport))

        XCTAssertEqual(fittedViewport.minX - actualViewport.minX, 15, accuracy: 0.001)
        XCTAssertEqual(actualViewport.maxX - fittedViewport.maxX, 15, accuracy: 0.001)
        XCTAssertEqual(fittedViewport.width, 970, accuracy: 0.001)
        XCTAssertEqual(fittedViewport.minY - actualViewport.minY, 10.5, accuracy: 0.001)
        XCTAssertEqual(actualViewport.maxY - fittedViewport.maxY, 10.5, accuracy: 0.001)
        XCTAssertNil(JotCanvasZoomCoordinator.pageFitViewport(.zero))
    }

    func testAfterPinchNextFitChoosesTheOppositeOfTheNearestPageFit() {
        let scales = JotCanvasZoomCoordinator.PageFitScales(shortSide: 1.6, longSide: 0.8)

        XCTAssertEqual(JotCanvasZoomCoordinator.nextFitMode(afterPinchAt: 1.58, scales: scales), .longSide)
        XCTAssertEqual(JotCanvasZoomCoordinator.nextFitMode(afterPinchAt: 0.83, scales: scales), .shortSide)
        XCTAssertEqual(JotCanvasZoomCoordinator.nextFitMode(afterPinchAt: 1.25, scales: scales), .longSide)
    }

    func testEqualFitTargetsRemainStableWithoutRequiringAnExtraZoomState() throws {
        let scales = try XCTUnwrap(
            JotCanvasZoomCoordinator.pageFitScales(
                pageSize: CGSize(width: 800, height: 1_000),
                viewportSize: CGSize(width: 800, height: 1_000)
            )
        )

        XCTAssertEqual(scales.shortSide, scales.longSide, accuracy: 0.0001)
        XCTAssertEqual(scales.scale(for: .shortSide), scales.scale(for: .longSide), accuracy: 0.0001)
    }
}
