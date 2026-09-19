//
//  Item.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import Foundation
import SwiftData

/// One book in the library.
///
/// Every property carries a declared default and no uniqueness constraint,
/// because this model syncs through CloudKit, which supports neither. `legacyID`
/// is kept distinct by `LibraryImporter` fetching before it inserts.
@Model
final class Item {
    var id: UUID = UUID()
    var legacyID: Int? // Stackroom legacy Book ID

    var volume: Volume?
    var relativePath: String = ""
    /// Where this item's own security-scoped bookmark used to live, before
    /// bookmarks moved to the device-local store. Emptied by
    /// `BookmarkVault.adoptBookmarksStoredOnModels` the first time a build with
    /// the local store runs, and readable until then so that move can find them.
    /// Nothing else reads or writes it; drop the property once every install has
    /// launched this version at least once.
    var bookmarkData: Data?
    var title: String = ""
    var author: String = ""
    var rating: Int = 0
    var isUnread: Bool = true
    var genre: String = ""
    var relation: String = ""
    var keywordA: String = ""
    var keywordB: String = ""
    var memo: String = ""
    var coverImageName: String = ""
    var coverImagePath: String = ""
    var addedDate: Date = Date()
    var lastReadDate: Date?
    var pages: Int = 0
    var bookType: Int = 0
    var fileType: Int = 0

    /// Which generation of this book's thumbnail the library holds. 0 means none
    /// has been made. Generating or re-picking a cover raises it, which is how
    /// other devices learn their cached copy is behind without listing the NAS.
    var coverVersion: Int = 0
    /// Size in bytes of the thumbnail `coverVersion` refers to, so a device can
    /// total up a download before starting one.
    var coverBytes: Int = 0

    var shelves: [Shelf]?

    init(
        id: UUID = UUID(),
        legacyID: Int? = nil,
        volume: Volume? = nil,
        relativePath: String,
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
        fileType: Int = 0,
        coverVersion: Int = 0,
        coverBytes: Int = 0
    ) {
        self.id = id
        self.legacyID = legacyID
        self.volume = volume
        self.relativePath = relativePath
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
        self.coverVersion = coverVersion
        self.coverBytes = coverBytes
        self.shelves = []
    }
}
