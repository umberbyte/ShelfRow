//
//  Item.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import Foundation
import SwiftData

@Model
final class Item {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var legacyID: Int? // Stackroom legacy Book ID
    
    var volume: Volume?
    var relativePath: String
    /// Item-level security-scoped bookmark (set when the file itself was
    /// user-selected, e.g. registered via drag & drop). Takes precedence
    /// over the volume-level bookmark when resolving the file.
    var bookmarkData: Data?
    var title: String
    var author: String
    var rating: Int
    var isUnread: Bool
    var genre: String
    var relation: String
    var keywordA: String
    var keywordB: String
    var memo: String
    var coverImageName: String
    var coverImagePath: String
    var addedDate: Date
    var lastReadDate: Date?
    var pages: Int
    var bookType: Int
    var fileType: Int
    
    var shelves: [Shelf]?
    
    init(
        id: UUID = UUID(),
        legacyID: Int? = nil,
        volume: Volume? = nil,
        relativePath: String,
        bookmarkData: Data? = nil,
        title: String,
        author: String = "",
        rating: Int = 0,
        isUnread: Bool = true,
        genre: String = "",
        relation: String = "",
        keywordA: String = "",
        keywordB: String = "",
        memo: String = "",
        coverImageName: String = "",
        coverImagePath: String = "",
        addedDate: Date = Date(),
        lastReadDate: Date? = nil,
        pages: Int = 0,
        bookType: Int = 0,
        fileType: Int = 0
    ) {
        self.id = id
        self.legacyID = legacyID
        self.volume = volume
        self.relativePath = relativePath
        self.bookmarkData = bookmarkData
        self.title = title
        self.author = author
        self.rating = rating
        self.isUnread = isUnread
        self.genre = genre
        self.relation = relation
        self.keywordA = keywordA
        self.keywordB = keywordB
        self.memo = memo
        self.coverImageName = coverImageName
        self.coverImagePath = coverImagePath
        self.addedDate = addedDate
        self.lastReadDate = lastReadDate
        self.pages = pages
        self.bookType = bookType
        self.fileType = fileType
        self.shelves = []
    }
}
