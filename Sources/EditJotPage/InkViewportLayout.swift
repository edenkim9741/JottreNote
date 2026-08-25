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

import CoreGraphics

/// Describes a bounded PencilKit viewport entirely in document coordinates.
///
/// No zoom scale participates in this layout. The outer document scroll view
/// applies the one and only visual transform to PDF and ink together.
struct InkViewportLayout: Equatable {

    let visibleDocumentRect: CGRect
    let allocatedDocumentRect: CGRect
    let documentSize: CGSize

    var viewportBounds: CGRect {
        CGRect(origin: .zero, size: allocatedDocumentRect.size)
    }

    var canvasContentOffset: CGPoint {
        allocatedDocumentRect.origin
    }

    static func make(
        visibleDocumentRect: CGRect,
        documentSize: CGSize,
        overscan: CGFloat
    ) -> InkViewportLayout? {
        guard isValid(documentSize), isValid(visibleDocumentRect) else { return nil }

        let documentBounds = CGRect(origin: .zero, size: documentSize)
        let visibleRect = visibleDocumentRect.standardized.intersection(documentBounds)
        guard isValid(visibleRect) else { return nil }

        let clampedOverscan = max(0, overscan)
        let proposedAllocation = visibleRect.insetBy(
            dx: -visibleRect.width * clampedOverscan,
            dy: -visibleRect.height * clampedOverscan
        )
        let allocatedRect = proposedAllocation.intersection(documentBounds)
        guard isValid(allocatedRect) else { return nil }

        return InkViewportLayout(
            visibleDocumentRect: visibleRect,
            allocatedDocumentRect: allocatedRect,
            documentSize: documentSize
        )
    }

    func reusingAllocatedDocumentRect(_ allocatedRect: CGRect) -> InkViewportLayout? {
        let documentBounds = CGRect(origin: .zero, size: documentSize)
        guard Self.isValid(allocatedRect),
            documentBounds.contains(allocatedRect),
            allocatedRect.contains(visibleDocumentRect)
        else { return nil }

        return InkViewportLayout(
            visibleDocumentRect: visibleDocumentRect,
            allocatedDocumentRect: allocatedRect,
            documentSize: documentSize
        )
    }

    func viewportPoint(forDocumentPoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x - canvasContentOffset.x,
            y: point.y - canvasContentOffset.y
        )
    }

    func documentPoint(forViewportPoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x + allocatedDocumentRect.minX,
            y: point.y + allocatedDocumentRect.minY
        )
    }

    private static func isValid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    private static func isValid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite
            && rect.minX.isFinite && rect.minY.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }
}
