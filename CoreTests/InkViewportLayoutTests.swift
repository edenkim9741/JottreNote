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

final class InkViewportLayoutTests: XCTestCase {

    func testDocumentPointRoundTripsThroughBufferedViewport() throws {
        let layout = try XCTUnwrap(
            InkViewportLayout.make(
                visibleDocumentRect: CGRect(x: 300, y: 2_000, width: 600, height: 800),
                documentSize: CGSize(width: 1_200, height: 10_000),
                overscan: 1
            )
        )
        let documentPoint = CGPoint(x: 725, y: 2_450)

        let viewportPoint = layout.viewportPoint(forDocumentPoint: documentPoint)

        XCTAssertEqual(layout.documentPoint(forViewportPoint: viewportPoint), documentPoint)
    }

    func testLayoutContainsVisibleRectAndClampsToDocument() throws {
        let layout = try XCTUnwrap(
            InkViewportLayout.make(
                visibleDocumentRect: CGRect(x: -100, y: -80, width: 700, height: 900),
                documentSize: CGSize(width: 1_200, height: 1_600),
                overscan: 1
            )
        )

        XCTAssertTrue(layout.allocatedDocumentRect.contains(layout.visibleDocumentRect))
        XCTAssertEqual(layout.allocatedDocumentRect.minX, 0)
        XCTAssertEqual(layout.allocatedDocumentRect.minY, 0)
        XCTAssertLessThanOrEqual(layout.allocatedDocumentRect.maxX, 1_200)
        XCTAssertLessThanOrEqual(layout.allocatedDocumentRect.maxY, 1_600)
    }

    func testExistingAllocationCanBeReusedAcrossZoomViewportChanges() throws {
        let initial = try XCTUnwrap(
            InkViewportLayout.make(
                visibleDocumentRect: CGRect(x: 200, y: 1_000, width: 600, height: 800),
                documentSize: CGSize(width: 1_200, height: 8_000),
                overscan: 1
            )
        )
        let zoomed = try XCTUnwrap(
            InkViewportLayout.make(
                visibleDocumentRect: CGRect(x: 350, y: 1_200, width: 300, height: 400),
                documentSize: initial.documentSize,
                overscan: 1
            )
        )

        let reused = try XCTUnwrap(
            zoomed.reusingAllocatedDocumentRect(initial.allocatedDocumentRect)
        )

        XCTAssertEqual(reused.allocatedDocumentRect, initial.allocatedDocumentRect)
    }

    func testInvalidGeometryDoesNotProduceLayout() {
        XCTAssertNil(
            InkViewportLayout.make(
                visibleDocumentRect: .zero,
                documentSize: CGSize(width: 1_200, height: 1_600),
                overscan: 1
            )
        )
        XCTAssertNil(
            InkViewportLayout.make(
                visibleDocumentRect: CGRect(x: 0, y: 0, width: 500, height: 500),
                documentSize: .zero,
                overscan: 1
            )
        )
    }
}
