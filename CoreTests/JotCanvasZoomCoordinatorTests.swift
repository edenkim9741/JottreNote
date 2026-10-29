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

    func testSmartTargetScaleUsesCurrentScaleRatherThanAStoredCycle() {
        let scales = JotCanvasZoomCoordinator.PageFitScales(shortSide: 1.6, longSide: 0.8)

        XCTAssertEqual(JotCanvasZoomCoordinator.targetScale(current: 0.5, scales: scales), 0.8)
        XCTAssertEqual(JotCanvasZoomCoordinator.targetScale(current: 0.8, scales: scales), 1.6)
        XCTAssertEqual(JotCanvasZoomCoordinator.targetScale(current: 1.2, scales: scales), 1.6)
        XCTAssertEqual(JotCanvasZoomCoordinator.targetScale(current: 1.6, scales: scales), 0.8)
        XCTAssertEqual(JotCanvasZoomCoordinator.targetScale(current: 2.4, scales: scales), 1.6)
    }

    func testPinchScaleAndRepeatedDoubleTapsChooseFromTheActualCurrentScale() {
        let scales = JotCanvasZoomCoordinator.PageFitScales(shortSide: 1.6, longSide: 0.8)

        let afterPinchIn = JotCanvasZoomCoordinator.targetScale(current: 2.25, scales: scales)
        XCTAssertEqual(afterPinchIn, 1.6)
        let afterFirstTap = JotCanvasZoomCoordinator.targetScale(current: afterPinchIn, scales: scales)
        XCTAssertEqual(afterFirstTap, 0.8)
        let afterSecondTap = JotCanvasZoomCoordinator.targetScale(current: afterFirstTap, scales: scales)
        XCTAssertEqual(afterSecondTap, 1.6)
    }

    func testFitScaleComparisonUsesSmallAbsoluteAndRelativeTolerance() {
        let scales = JotCanvasZoomCoordinator.PageFitScales(shortSide: 1.6, longSide: 0.8)

        XCTAssertEqual(JotCanvasZoomCoordinator.targetScale(current: 1.603, scales: scales), 0.8)
        XCTAssertEqual(JotCanvasZoomCoordinator.targetScale(current: 0.799, scales: scales), 1.6)
        XCTAssertEqual(JotCanvasZoomCoordinator.targetScale(current: 1.58, scales: scales), 1.6)
        XCTAssertEqual(JotCanvasZoomCoordinator.targetScale(current: 0.83, scales: scales), 1.6)
    }

    func testPageFitViewportKeepsHorizontalGuttersAndFullVerticalFitArea() throws {
        let actualViewport = CGRect(x: 12, y: 30, width: 1_000, height: 700)
        let fittedViewport = try XCTUnwrap(JotCanvasZoomCoordinator.pageFitViewport(actualViewport))

        XCTAssertEqual(fittedViewport.minX - actualViewport.minX, 15, accuracy: 0.001)
        XCTAssertEqual(actualViewport.maxX - fittedViewport.maxX, 15, accuracy: 0.001)
        XCTAssertEqual(fittedViewport.width, 970, accuracy: 0.001)
        XCTAssertEqual(fittedViewport.minY, actualViewport.minY, accuracy: 0.001)
        XCTAssertEqual(fittedViewport.maxY, actualViewport.maxY, accuracy: 0.001)
        XCTAssertEqual(fittedViewport.height, actualViewport.height, accuracy: 0.001)
        XCTAssertNil(JotCanvasZoomCoordinator.pageFitViewport(.zero))
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
