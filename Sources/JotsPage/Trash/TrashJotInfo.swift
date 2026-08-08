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

import Foundation

struct TrashJotInfo: Hashable, Sendable {
    let trashURL: URL
    let trashInfoURL: URL
    let originalURL: URL
    let name: String
    let deletedDate: Date
    let modificationDate: Date?
    /// Non-nil when this item is a deleted page rather than a whole file.
    let sourceJotURL: URL?
    let deletedPageIndex: Int?
    let pageStride: CGFloat?
}
