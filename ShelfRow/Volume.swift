//
//  Volume.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import Foundation
import SwiftData

@Model
final class Volume {
    @Attribute(.unique) var id: UUID
    var name: String
    var lastKnownPath: String
    var bookmarkData: Data?
    
    @Relationship(deleteRule: .cascade, inverse: \Item.volume)
    var items: [Item]?
    
    init(id: UUID = UUID(), name: String, lastKnownPath: String, bookmarkData: Data? = nil) {
        self.id = id
        self.name = name
        self.lastKnownPath = lastKnownPath
        self.bookmarkData = bookmarkData
        self.items = []
    }
}
