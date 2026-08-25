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
}
