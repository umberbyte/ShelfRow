import Foundation
import SwiftData
import Testing
@testable import ShelfRow

@MainActor
struct LibraryImporterTests {
    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "LibraryImporterTests",
            schema: Schema(LibraryStore.libraryModels),
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: Schema(LibraryStore.libraryModels),
            configurations: configuration
        )
    }

    private func writeLibrary(books: [String: Any], playlists: [[String: Any]]) throws -> URL {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Books": books, "Playlists": playlists],
            format: .xml,
            options: 0
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Stackroom-Library-\(UUID().uuidString).xml")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func importLibrary(_ url: URL, into container: ModelContainer) async throws -> (booksCount: Int, playlistsCount: Int) {
        defer { try? FileManager.default.removeItem(at: url) }
        let importer = LibraryImporter(modelContainer: container)
        return try await importer.importLibrary(from: url) { _, _, _, _ in }
    }

    @Test func importsAllFiveStackroomTextFieldsUsingTheirActualXMLKeys() async throws {
        let container = try makeContainer()
        let url = try writeLibrary(
            books: [
                "25192": [
                    "ID": 25192,
                    "Title": "未熟な君のせい",
                    // Item 25192 in the supplied library has no Path key.
                    "Cover Image Path": "/Volumes/Files/files/com/単行本/未熟な君のせい.zip",
                    "Genre": "ジャンルの内容",
                    "Keyword A": "キーワードAの内容",
                    "Keyword B": "キーワードBの内容",
                    "Memo": "めもめもめおも",
                    "Neta": "関連の内容"
                ]
            ],
            playlists: []
        )

        let result = try await importLibrary(url, into: container)
        let items = try container.mainContext.fetch(FetchDescriptor<Item>())
        let item = try #require(items.first)

        #expect(result.booksCount == 1)
        #expect(item.legacyID == 25192)
        #expect(item.relativePath == "files/com/単行本/未熟な君のせい.zip")
        #expect(item.genre == "ジャンルの内容")
        #expect(item.keywordA == "キーワードAの内容")
        #expect(item.keywordB == "キーワードBの内容")
        #expect(item.memo == "めもめもめおも")
        #expect(item.relation == "関連の内容")
    }

    @Test func repeatedImportAddsBooksAndShelfMembershipWithoutDeletingExistingData() async throws {
        let container = try makeContainer()
        let firstURL = try writeLibrary(
            books: [
                "1": ["ID": 1, "Title": "既存1", "Path": "/Volumes/Books/既存1.zip"],
                "2": ["ID": 2, "Title": "XMLから消える既存本", "Path": "/Volumes/Books/既存2.zip"]
            ],
            playlists: [["Title": "単行本", "Type": 0, "Items": [1, 2]]]
        )
        _ = try await importLibrary(firstURL, into: container)

        let firstItems = try container.mainContext.fetch(FetchDescriptor<Item>())
        let firstBook = try #require(firstItems.first { $0.legacyID == 1 })
        // Reproduce the previous importer bug: Neta was stored in memo.
        firstBook.genre = ""
        firstBook.relation = ""
        firstBook.memo = "関連の内容"
        try container.mainContext.save()

        let secondURL = try writeLibrary(
            books: [
                "1": [
                    "ID": 1,
                    "Title": "既存1",
                    "Path": "/Volumes/Books/既存1.zip",
                    "Genre": "ジャンルの内容",
                    "Keyword A": "A",
                    "Keyword B": "B",
                    "Memo": "本来のメモ",
                    "Neta": "関連の内容"
                ],
                "3": [
                    "ID": 3,
                    "Title": "差分追加",
                    // Stackroom IDs are authoritative. A newly assigned ID must
                    // be imported even when it points at an existing file.
                    "Path": "/Volumes/Books/既存1.zip",
                    "Genre": "追加ジャンル",
                    "Neta": "追加関連",
                    "memo": "小文字のメモ"
                ]
            ],
            playlists: [
                ["Title": "単行本", "Type": 0, "Items": [1, 3]],
                ["Title": "新しい棚", "Type": 0, "Items": [3]]
            ]
        )

        let result = try await importLibrary(secondURL, into: container)
        let items = try container.mainContext.fetch(FetchDescriptor<Item>())
        let repaired = try #require(items.first { $0.legacyID == 1 })
        let added = try #require(items.first { $0.legacyID == 3 })
        let shelves = try container.mainContext.fetch(FetchDescriptor<Shelf>())
        let existingShelf = try #require(shelves.first { $0.title == "単行本" })
        let newShelf = try #require(shelves.first { $0.title == "新しい棚" })

        #expect(result.booksCount == 1)
        #expect(result.playlistsCount == 1)
        #expect(Set(items.compactMap(\.legacyID)) == [1, 2, 3])
        #expect(repaired.genre == "ジャンルの内容")
        #expect(repaired.keywordA == "A")
        #expect(repaired.keywordB == "B")
        #expect(repaired.relation == "関連の内容")
        #expect(repaired.memo == "本来のメモ")
        #expect(added.genre == "追加ジャンル")
        #expect(added.relation == "追加関連")
        #expect(added.memo == "小文字のメモ")
        #expect(Set(existingShelf.items?.compactMap(\.legacyID) ?? []) == [1, 2, 3])
        #expect(Set(newShelf.items?.compactMap(\.legacyID) ?? []) == [3])
    }
}
