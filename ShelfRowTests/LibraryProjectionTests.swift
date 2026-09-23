import Foundation
import Testing
import OSLog
import AppKit
import ImageIO
import SwiftData
@testable import ShelfRow

@MainActor
struct LibraryProjectionTests {
    private func request(search: String = "", selection: SidebarSelection? = .allBooks,
                         ascending: Bool = true, key: ItemSortKey = .title,
                         ratings: Set<Int> = [], types: Set<Int> = [], aliases: String = "[]") -> LibraryProjectionRequest {
        LibraryProjectionRequest(selection: selection, search: search, equivalenceJSON: aliases,
                                 unreadOnly: false, ratings: ratings, types: types, sortKey: key, ascending: ascending)
    }

    @Test func naturalOrderFiltersAndShelfCounts() async throws {
        let a = Item(relativePath: "a", title: "Book 10", rating: 5, isUnread: false, bookType: 2)
        let b = Item(relativePath: "b", title: "Book 2", rating: 2)
        let c = Item(relativePath: "c", title: "Book 1", rating: 5, bookType: 2)
        let rows = [a, b, c].map(LibraryItemSnapshot.init)
        let staticID = UUID(), smartID = UUID()
        let shelves = [LibraryShelfSnapshot(id: staticID, conditions: nil, itemIDs: [a.id, c.id]),
                       LibraryShelfSnapshot(id: smartID, conditions: SmartConditions(unreadOnly: true), itemIDs: [])]
        let worker = LibraryProjectionWorker()
        let all = try await worker.project(rows, shelves: shelves, request: request())
        #expect(all.ids == [c.id, b.id, a.id])
        #expect(all.unreadCount == 2)
        #expect(all.shelfCounts == [staticID: 2, smartID: 2])
        let subset = try await worker.project(rows, shelves: shelves,
            request: request(selection: .shelf(staticID), ascending: false, ratings: [5], types: [2]))
        #expect(subset.ids == [a.id, c.id])
        let smart = try await worker.project(rows, shelves: shelves, request: request(selection: .shelf(smartID)))
        #expect(smart.ids == [c.id, b.id])
    }

    @Test func normalizedSearchAliasesAndEditsInvalidateCaches() async throws {
        let a = Item(relativePath: "a", title: "Ｃａｆé 10", author: "旧作者")
        let b = Item(relativePath: "b", title: "Book 2", author: "別名")
        let worker = LibraryProjectionWorker()
        var rows = [a, b].map(LibraryItemSnapshot.init)
        let folded = try await worker.project(rows, shelves: [], request: request(search: "cafe"))
        #expect(folded.ids == [a.id])
        let aliases = KeywordEquivalenceCodec.encode([KeywordEquivalenceRule(field: .author, terms: ["作者", "別名"])])
        let aliased = try await worker.project(rows, shelves: [], request: request(search: "作者", aliases: aliases))
        #expect(Set(aliased.ids) == [a.id, b.id])
        a.title = "Book 0"; a.author = "変更済み"; a.isUnread = false
        rows = [a, b].map(LibraryItemSnapshot.init)
        let changed = try await worker.project(rows, shelves: [], request: request(search: "cafe"), generation: 1)
        #expect(changed.ids.isEmpty)
        #expect(changed.unreadCount == 1)
        let ordered = try await worker.project(rows, shelves: [], request: request(), generation: 1)
        #expect(ordered.ids == [a.id, b.id])
        let removed = try await worker.project([LibraryItemSnapshot(b)], shelves: [], request: request(), generation: 2)
        #expect(removed.ids == [b.id])
    }

    @Test func cancelledQueryDoesNotPoisonNextResult() async throws {
        let rows = (0..<200).map { LibraryItemSnapshot(Item(relativePath: "\($0)", title: "Book \($0)")) }
        let worker = LibraryProjectionWorker()
        let query = request()
        let pending = Task { try await worker.project(rows, shelves: [], request: query) }
        pending.cancel()
        do { _ = try await pending.value; Issue.record("Cancelled query completed") }
        catch is CancellationError {} catch { throw error }
        let result = try await worker.project(rows, shelves: [], request: request(ascending: false))
        #expect(result.ids == rows.reversed().map(\.id))
    }

    @Test func changingShelfRulesAndDateConditionsRefreshCounts() async throws {
        let now = Date()
        let recent = Item(relativePath: "a", title: "Recent", addedDate: now)
        let old = Item(relativePath: "b", title: "Old", addedDate: now.addingTimeInterval(-86400 * 60))
        let id = UUID()
        let rows = [recent, old].map(LibraryItemSnapshot.init)
        let worker = LibraryProjectionWorker()
        var conditions = SmartConditions(date: .init(field: 0, days: 30, mode: 0))
        var shelves = [LibraryShelfSnapshot(id: id, conditions: conditions, itemIDs: [])]
        let first = try await worker.project(rows, shelves: shelves, request: request(selection: .shelf(id)))
        #expect(first.ids == [recent.id])
        conditions.date?.mode = 1
        shelves = [LibraryShelfSnapshot(id: id, conditions: conditions, itemIDs: [])]
        let changed = try await worker.project(rows, shelves: shelves, request: request(selection: .shelf(id)), generation: 1)
        #expect(changed.ids == [old.id])
        #expect(changed.shelfCounts[id] == 1)
    }

    @Test func diskThumbnailDecodeIsBoundedWithoutChangingOriginal() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = try #require(CGContext(data: nil, width: 2048, height: 1024,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let original = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, original, nil)
        #expect(CGImageDestinationFinalize(destination))
        let before = try Data(contentsOf: url)
        let image = try #require(ThumbnailCache.loadCachedThumbnail(at: url))
        let rep = try #require(image.representations.first)
        #expect(rep.pixelsWide == 768)
        #expect(rep.pixelsHigh == 384)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func twentyThousandItemsBenchmark() async throws {
        let rows = (0..<20_000).map { LibraryItemSnapshot(Item(relativePath: "\($0)", title: "Book \($0)", isUnread: $0.isMultiple(of: 2))) }
        let worker = LibraryProjectionWorker()
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await worker.project(rows.reversed(), shelves: [], request: request())
        let cold = start.duration(to: clock.now)
        let second = clock.now
        let reverse = try await worker.project(rows.reversed(), shelves: [], request: request(ascending: false))
        let warm = second.duration(to: clock.now)
        #expect(result.ids == rows.map(\.id))
        #expect(reverse.ids == rows.reversed().map(\.id))
        #expect(result.unreadCount == 10_000)
        Logger(subsystem: "com.eureka.ShelfRow", category: "PerformanceTests").notice("20k projection cold=\(String(describing: cold), privacy: .public) warm=\(String(describing: warm), privacy: .public)")
    }

    @Test func cloudSyncBurstsSkipMainContextIdentifierResolution() {
        #expect(!LibraryRefreshPolicy.requiresFullSnapshot(
            hasStructuralChange: false,
            updatedItemCount: LibraryRefreshPolicy.maximumPatchedItems,
            relevantChangeCount: LibraryRefreshPolicy.maximumPatchedItems
        ))
        #expect(LibraryRefreshPolicy.requiresFullSnapshot(
            hasStructuralChange: false,
            updatedItemCount: LibraryRefreshPolicy.maximumPatchedItems + 1,
            relevantChangeCount: LibraryRefreshPolicy.maximumPatchedItems + 1
        ))
        #expect(LibraryRefreshPolicy.requiresFullSnapshot(
            hasStructuralChange: true,
            updatedItemCount: 1,
            relevantChangeCount: 1
        ))
        #expect(LibraryRefreshPolicy.requiresFullSnapshot(
            hasStructuralChange: false,
            updatedItemCount: 1,
            relevantChangeCount: 2
        ))
    }

    @Test func snapshotReaderReturnsValueCopiesFromItsModelActor() async throws {
        let schema = Schema(LibraryStore.libraryModels)
        let configuration = ModelConfiguration(
            "Library",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: configuration)
        let item = Item(relativePath: "book.zip", title: "同期中も表示できる本", author: "作者")
        let shelf = Shelf(title: "本棚", icon: 0, type: 0)
        shelf.items = [item]
        container.mainContext.insert(item)
        container.mainContext.insert(shelf)
        try container.mainContext.save()

        let payload = try await LibrarySnapshotReader(modelContainer: container).read()

        #expect(payload.items == [LibraryItemSnapshot(item)])
        #expect(payload.shelves == [LibraryShelfSnapshot(id: shelf.id, conditions: nil, itemIDs: [item.id])])
    }

    @Test func snapshotReaderIsCreatedAwayFromTheMainThread() async throws {
        let schema = Schema(LibraryStore.libraryModels)
        let configuration = ModelConfiguration(
            "Library",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: configuration)

        let reader = await LibrarySnapshotLoader.makeReader(modelContainer: container)
        let isMainThread = await reader.isExecutingOnMainThread()

        #expect(isMainThread == false)
    }

    @Test func listRowsKeepProjectionOrderAndPreformatDates() {
        let first = LibraryItemSnapshot(
            Item(relativePath: "1", title: "First", addedDate: Date(timeIntervalSince1970: 0))
        )
        let second = LibraryItemSnapshot(
            Item(relativePath: "2", title: "Second", lastReadDate: Date(timeIntervalSince1970: 86_400))
        )

        let rows = LibraryListSnapshot.rows(
            orderedIDs: [second.id, first.id],
            snapshots: [first, second]
        )

        #expect(rows.map(\.id) == [second.id, first.id])
        #expect(rows[0].lastReadDateText != "—")
        #expect(rows[1].lastReadDateText == "—")
        #expect(!rows[0].addedDateText.isEmpty)
    }
}
