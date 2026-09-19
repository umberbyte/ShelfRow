//
//  Volume.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import Foundation
import SwiftData

/// A mount point holding books — an external drive, a NAS share.
///
/// `lastKnownPath` syncs and is only ever a hint: each device resolves the
/// volume through its own bookmark, which stays in the device-local store.
@Model
final class Volume {
    var id: UUID = UUID()
    var name: String = ""
    var lastKnownPath: String = ""
    /// See `Item.bookmarkData` — migration source only, emptied on first launch.
    var bookmarkData: Data?

    @Relationship(deleteRule: .cascade, inverse: \Item.volume)
    var items: [Item]?

    init(id: UUID = UUID(), name: String, lastKnownPath: String) {
        self.id = id
        self.name = name
        self.lastKnownPath = lastKnownPath
        self.items = []
    }
}
