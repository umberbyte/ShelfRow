import Foundation
import SwiftData
import Testing
@testable import ShelfRow

@MainActor
struct DuplicateRecordResolverTests {
    private func makeContainer() throws -> ModelContainer {
        let library = ModelConfiguration(
            "Library",
            schema: Schema(LibraryStore.libraryModels),
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let local = ModelConfiguration(
            "Local",
            schema: Schema(LibraryStore.localModels),
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: Schema(LibraryStore.libraryModels + LibraryStore.localModels),
            configurations: library, local
        )
    }

    @Test func mergesDuplicateLegacyRecordsWithoutLosingRelationshipsOrLocalState() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let survivorID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
        let duplicateID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000002"))
        let volume = Volume(name: "Books", lastKnownPath: "/Volumes/Books")
        let survivor = Item(
            id: survivorID,
            legacyID: 25192,
            volume: volume,
            relativePath: "comic.zip",
            title: "",
            rating: 2,
            isUnread: true,
            addedDate: Date(timeIntervalSince1970: 200),
            coverVersion: 1,
            coverBytes: 100
        )
        let duplicate = Item(
            id: duplicateID,
            legacyID: 25192,
            volume: volume,
            relativePath: "comic.zip",
            title: "作品名",
            author: "作者",
            rating: 5,
            isUnread: false,
            memo: "残すメモ",
            addedDate: Date(timeIntervalSince1970: 100),
            lastReadDate: Date(timeIntervalSince1970: 300),
            pages: 120,
            coverVersion: 3,
            coverBytes: 300
        )
        let firstShelf = Shelf(title: "本棚A", icon: 0, type: 0)
        let secondShelf = Shelf(title: "本棚B", icon: 0, type: 0)
        firstShelf.items = [survivor]
        secondShelf.items = [duplicate]
        context.insert(volume)
        context.insert(survivor)
        context.insert(duplicate)
        context.insert(firstShelf)
        context.insert(secondShelf)
        context.insert(CoverExtractionRecord(
            itemID: duplicateID,
            outcome: .generated,
            updatedAt: Date(timeIntervalSince1970: 400)
        ))
        context.insert(LocalBookmark(
            targetID: survivorID,
            data: Data(),
            updatedAt: Date(timeIntervalSince1970: 500)
        ))
        context.insert(LocalBookmark(
            targetID: duplicateID,
            data: Data([1, 2, 3]),
            updatedAt: Date(timeIntervalSince1970: 100)
        ))
        context.insert(LocalCoverState(itemID: duplicateID, version: 3, bytes: 300, pendingUpload: true))
        try context.save()

        let resolver = DuplicateRecordResolver(modelContainer: container)
        let preview = try await resolver.preview()
        #expect(preview.groupCount == 1)
        #expect(preview.duplicateCount == 1)

        let result = try await resolver.resolve()
        #expect(result.groupCount == 1)
        #expect(result.duplicateCount == 1)

        let items = try context.fetch(FetchDescriptor<Item>())
        let merged = try #require(items.first)
        #expect(items.count == 1)
        #expect(merged.id == survivorID)
        #expect(merged.title == "作品名")
        #expect(merged.author == "作者")
        #expect(merged.memo == "残すメモ")
        #expect(merged.rating == 5)
        #expect(!merged.isUnread)
        #expect(merged.addedDate == Date(timeIntervalSince1970: 100))
        #expect(merged.lastReadDate == Date(timeIntervalSince1970: 300))
        #expect(merged.pages == 120)
        #expect(merged.coverVersion == 3)
        #expect(merged.coverBytes == 300)
        #expect(Set(merged.shelves?.map(\.title) ?? []) == ["本棚A", "本棚B"])

        let records = try context.fetch(FetchDescriptor<CoverExtractionRecord>())
        #expect(records.count == 1)
        #expect(records.first?.itemID == survivorID)
        let bookmarks = try context.fetch(FetchDescriptor<LocalBookmark>())
        #expect(bookmarks.count == 1)
        #expect(bookmarks.first?.targetID == survivorID)
        #expect(bookmarks.first?.data == Data([1, 2, 3]))
        let coverStates = try context.fetch(FetchDescriptor<LocalCoverState>())
        #expect(coverStates.count == 1)
        #expect(coverStates.first?.itemID == survivorID)
        #expect(coverStates.first?.version == 3)
        #expect(coverStates.first?.pendingUpload == true)
    }

    @Test func mergesPathDuplicatesOnlyWhenTheyHaveNoLegacyIdentityAndShareAVolume() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let firstVolume = Volume(name: "NAS", lastKnownPath: "/Volumes/NAS")
        let duplicateVolume = Volume(name: "NAS copy", lastKnownPath: "/Volumes/NAS/")
        let otherVolume = Volume(name: "Other", lastKnownPath: "/Volumes/Other")
        let first = Item(volume: firstVolume, relativePath: "Books/book.zip", title: "A")
        let duplicate = Item(volume: duplicateVolume, relativePath: "Books/./book.zip", title: "A")
        let distinctVolume = Item(volume: otherVolume, relativePath: "Books/book.zip", title: "A")
        let distinctLegacy = Item(legacyID: 99, volume: firstVolume, relativePath: "Books/book.zip", title: "A")
        for volume in [firstVolume, duplicateVolume, otherVolume] { context.insert(volume) }
        for item in [first, duplicate, distinctVolume, distinctLegacy] { context.insert(item) }
        try context.save()

        let result = try await DuplicateRecordResolver(modelContainer: container).resolve()

        #expect(result.groupCount == 1)
        #expect(result.duplicateCount == 1)
        let remaining = try context.fetch(FetchDescriptor<Item>())
        #expect(remaining.count == 3)
        #expect(remaining.contains { $0.legacyID == 99 })
        #expect(remaining.contains { $0.volume?.lastKnownPath == "/Volumes/Other" })
    }
}
