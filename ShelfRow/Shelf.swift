//
//  Shelf.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import Foundation
import SwiftData

@Model
final class Shelf {
    @Attribute(.unique) var id: UUID
    var title: String
    var icon: Int
    var type: Int // 0 = standard, 1 = smart
    var sortOrder: Int = 0
    var sortAscending: Bool
    var sortKey: String
    var smartConditionsJson: String?
    
    @Relationship(inverse: \Item.shelves)
    var items: [Item]?
    
    init(id: UUID = UUID(), title: String, icon: Int, type: Int, sortOrder: Int = 0, sortAscending: Bool = true, sortKey: String = "title", smartConditionsJson: String? = nil) {
        self.id = id
        self.title = title
        self.icon = icon
        self.type = type
        self.sortOrder = sortOrder
        self.sortAscending = sortAscending
        self.sortKey = sortKey
        self.smartConditionsJson = smartConditionsJson
        self.items = []
    }
}
