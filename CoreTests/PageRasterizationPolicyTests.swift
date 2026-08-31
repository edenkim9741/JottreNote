/*
 Jottre: Minimalistic jotting for iPhone, iPad and Mac.
 Copyright (C) 2021-2026 Anton Lorani

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

import XCTest

@testable import Jottre

final class PageRasterizationPolicyTests: XCTestCase {

    func testSettledScaleUsesQuantizedTiers() {
        let pageSize = CGSize(width: 1_200, height: 1_600)

        XCTAssertEqual(
            PageRasterizationPolicy.settledScale(
                zoomScale: 0.5,
                displayScale: 2,
                pageSize: pageSize
            ),
            1
        )
        XCTAssertEqual(
            PageRasterizationPolicy.settledScale(
                zoomScale: 0.7,
                displayScale: 2,
                pageSize: pageSize
            ),
            1.5
        )
        XCTAssertEqual(
            PageRasterizationPolicy.settledScale(
                zoomScale: 1,
                displayScale: 2,
                pageSize: pageSize
            ),
            2
        )
    }

    func testSettledScaleCapsLongestBitmapEdge() {
        let scale = PageRasterizationPolicy.settledScale(
            zoomScale: 4,
            displayScale: 2,
            pageSize: CGSize(width: 1_200, height: 3_200)
        )

        XCTAssertEqual(scale, 1.28, accuracy: 0.001)
    }

    func testPageRangeAccountsForZoomAndNegativeTopInset() {
        let range = PageRasterizationPolicy.pageRange(
            pageCount: 10,
            pageHeight: 1_600,
            pageSpacing: 32,
            scrollOffsetY: -80,
            viewportHeight: 1_000,
            zoomScale: 0.5,
            overscan: 0
        )

        XCTAssertEqual(range, 0...1)
    }

    func testPrefetchRangeClampsToDocumentEdges() {
        let range = PageRasterizationPolicy.pageRange(
            pageCount: 4,
            pageHeight: 1_600,
            pageSpacing: 32,
            scrollOffsetY: 4_800,
            viewportHeight: 1_000,
            zoomScale: 1,
            overscan: 3
        )

        XCTAssertEqual(range, 0...3)
    }

    // MARK: - Detail requests

    func testNoDetailRequestWhenWholePageBitmapAlreadyResolvesEveryPixel() {
        let pageSize = CGSize(width: 1_200, height: 1_600)

        XCTAssertNil(
            PageRasterizationPolicy.detailRequest(
                visiblePageRect: CGRect(x: 0, y: 0, width: 1_200, height: 900),
                pageSize: pageSize,
                zoomScale: 1,
                displayScale: 2,
                baseScale: 2
            )
        )
    }

    func testDetailRequestRaisesResolutionForZoomedViewport() throws {
        let pageSize = CGSize(width: 1_200, height: 1_600)
        // At zoom 4 a viewport only ever exposes a page slice this small, so the
        // request reaches the full zoom * displayScale resolution.
        let visibleRect = CGRect(x: 400, y: 400, width: 209, height: 303)

        let request = try XCTUnwrap(
            PageRasterizationPolicy.detailRequest(
                visiblePageRect: visibleRect,
                pageSize: pageSize,
                zoomScale: 4,
                displayScale: 2,
                baseScale: 2
            )
        )

        XCTAssertEqual(request.scale, 8)
        // The rendered region is padded so small scrolls reuse the same bitmap.
        XCTAssertTrue(request.sourceRect.contains(visibleRect))
    }

    /// A visible rect far larger than any real viewport is bounded by the pixel
    /// budget rather than reaching the requested scale. This keeps one page's
    /// detail bitmap affordable no matter what geometry is asked for.
    func testDetailRequestClampsOversizedRegionToPixelBudget() throws {
        let pageSize = CGSize(width: 1_200, height: 1_600)

        let request = try XCTUnwrap(
            PageRasterizationPolicy.detailRequest(
                visiblePageRect: CGRect(x: 400, y: 400, width: 300, height: 400),
                pageSize: pageSize,
                zoomScale: 4,
                displayScale: 2,
                baseScale: 2
            )
        )

        XCTAssertLessThan(request.scale, 8)
        XCTAssertGreaterThan(request.scale, 2)
        let pixels =
            request.sourceRect.width * request.scale
            * request.sourceRect.height * request.scale
        XCTAssertLessThanOrEqual(pixels, PageRasterizationPolicy.maximumDetailPixels + 1)
    }

    func testDetailRequestStaysInsidePageBounds() throws {
        let pageSize = CGSize(width: 1_200, height: 1_600)

        let request = try XCTUnwrap(
            PageRasterizationPolicy.detailRequest(
                visiblePageRect: CGRect(x: -200, y: -200, width: 600, height: 600),
                pageSize: pageSize,
                zoomScale: 4,
                displayScale: 2,
                baseScale: 2
            )
        )

        XCTAssertTrue(CGRect(origin: .zero, size: pageSize).contains(request.sourceRect))
    }

    func testDetailRequestBoundsPixelBudgetForLargeViewport() throws {
        let pageSize = CGSize(width: 1_200, height: 1_600)

        let request = try XCTUnwrap(
            PageRasterizationPolicy.detailRequest(
                visiblePageRect: CGRect(origin: .zero, size: pageSize),
                pageSize: pageSize,
                zoomScale: 8,
                displayScale: 2,
                baseScale: 2
            )
        )

        XCTAssertGreaterThan(request.scale, 2)
        let pixels =
            request.sourceRect.width * request.scale
            * request.sourceRect.height * request.scale
        XCTAssertLessThanOrEqual(pixels, PageRasterizationPolicy.maximumDetailPixels + 1)
    }

    // MARK: - Vector layer density

    func testVectorLayerContentsScaleFollowsZoomAndIsCapped() {
        // Below 1x the display scale still sets the floor.
        XCTAssertEqual(
            PageRasterizationPolicy.vectorLayerContentsScale(zoomScale: 0.5, displayScale: 2),
            2
        )
        XCTAssertEqual(
            PageRasterizationPolicy.vectorLayerContentsScale(zoomScale: 3, displayScale: 2),
            6
        )
        // 8x zoom on a 3x display needs 24, which the ceiling now admits.
        XCTAssertEqual(
            PageRasterizationPolicy.vectorLayerContentsScale(zoomScale: 8, displayScale: 3),
            24
        )
        XCTAssertEqual(
            PageRasterizationPolicy.vectorLayerContentsScale(zoomScale: 40, displayScale: 3),
            PageRasterizationPolicy.maximumVectorLayerContentsScale
        )
    }

    func testVectorLayerContentsScaleRejectsInvalidZoom() {
        XCTAssertEqual(
            PageRasterizationPolicy.vectorLayerContentsScale(zoomScale: 0, displayScale: 2),
            2
        )
        XCTAssertEqual(
            PageRasterizationPolicy.vectorLayerContentsScale(
                zoomScale: .nan,
                displayScale: 2
            ),
            2
        )
    }
}
