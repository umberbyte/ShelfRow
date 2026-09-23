import Foundation
import Observation
import OSLog
import SwiftData
import SwiftUI

/// IDs are captured once per result, avoiding managed-property reads during
/// SwiftUI's identity scan of the entire lazy collection on every keypress.
struct LibraryDisplayRow: Identifiable {
    let id: UUID
    let index: Int
    let item: Item
}

/// Only these panes observe rapidly changing selection; the root and sidebar do not.
struct LibraryPane<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View { content() }
}

@MainActor @Observable
final class LibrarySelectionState {
    @ObservationIgnored var prefetchTask: Task<Void, Never>?
    var itemID: UUID?
    var itemIDs: Set<UUID> = []
    var anchorID: UUID?
    var index: Int?
    var lastScrollIndex: Int?
    var scrollTargetID: UUID?
}

struct LibraryItemSnapshot: Sendable, Equatable {
    let id: UUID
    let title, author, genre, relation, keywordA, keywordB, memo: String
    let rating, bookType, pages: Int
    let isUnread: Bool
    let addedDate: Date
    let lastReadDate: Date?
    let addedDateText: String
    let lastReadDateText: String

    @MainActor init(_ item: Item) {
        self.init(
            id: item.id,
            title: item.title,
            author: item.author,
            genre: item.genre,
            relation: item.relation,
            keywordA: item.keywordA,
            keywordB: item.keywordB,
            memo: item.memo,
            rating: item.rating,
            bookType: item.bookType,
            pages: item.pages,
            isUnread: item.isUnread,
            addedDate: item.addedDate,
            lastReadDate: item.lastReadDate
        )
    }

    nonisolated init(
        id: UUID,
        title: String,
        author: String,
        genre: String,
        relation: String,
        keywordA: String,
        keywordB: String,
        memo: String,
        rating: Int,
        bookType: Int,
        pages: Int,
        isUnread: Bool,
        addedDate: Date,
        lastReadDate: Date?
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.genre = genre
        self.relation = relation
        self.keywordA = keywordA
        self.keywordB = keywordB
        self.memo = memo
        self.rating = rating
        self.bookType = bookType
        self.pages = pages
        self.isUnread = isUnread
        self.addedDate = addedDate
        self.lastReadDate = lastReadDate
        self.addedDateText = addedDate.formatted(date: .numeric, time: .omitted)
        self.lastReadDateText = lastReadDate?.formatted(date: .numeric, time: .omitted) ?? "—"
    }

    nonisolated func value(for field: KeywordEquivalenceField) -> String {
        switch field {
        case .author: author
        case .genre: genre
        case .relation: relation
        case .keywordA: keywordA
        case .keywordB: keywordB
        case .memo: memo
        }
    }
}

struct LibraryShelfSnapshot: Sendable, Equatable {
    let id: UUID
    let conditions: SmartConditions?
    let itemIDs: Set<UUID>
}

struct LibrarySnapshotPayload: Sendable, Equatable {
    let items: [LibraryItemSnapshot]
    let shelves: [LibraryShelfSnapshot]
}

struct LibraryListRowSnapshot: Identifiable, Sendable, Equatable {
    let id: UUID
    let title: String
    let author: String
    let genre: String
    let relation: String
    let keywordA: String
    let keywordB: String
    let rating: Int
    let bookType: Int
    let pages: Int
    let isUnread: Bool
    let addedDateText: String
    let lastReadDateText: String

    nonisolated init(_ item: LibraryItemSnapshot) {
        id = item.id
        title = item.title
        author = item.author
        genre = item.genre
        relation = item.relation
        keywordA = item.keywordA
        keywordB = item.keywordB
        rating = item.rating
        bookType = item.bookType
        pages = item.pages
        isUnread = item.isUnread
        addedDateText = item.addedDateText
        lastReadDateText = item.lastReadDateText
    }
}

nonisolated enum LibraryListSnapshot {
    static func rows(
        orderedIDs: [UUID],
        snapshots: [LibraryItemSnapshot]
    ) -> [LibraryListRowSnapshot] {
        var byID: [UUID: LibraryItemSnapshot] = [:]
        byID.reserveCapacity(snapshots.count)
        for snapshot in snapshots {
            byID[snapshot.id] = snapshot
        }
        return orderedIDs.compactMap { id in
            byID[id].map(LibraryListRowSnapshot.init)
        }
    }
}

/// Reads the CloudKit-backed store on its own actor executor. A remote import can
/// fault thousands of fields at once; doing that through ContentView's main
/// context makes pointer movement and scrolling wait behind SQLite.
actor LibrarySnapshotReader {
    private let modelContext: ModelContext

    init(modelContainer: ModelContainer) {
        self.modelContext = ModelContext(modelContainer)
    }

    func read() async throws -> LibrarySnapshotPayload {
        let models = try modelContext.fetch(FetchDescriptor<Item>())
        var items: [LibraryItemSnapshot] = []
        items.reserveCapacity(models.count)
        for (index, item) in models.enumerated() {
            try Task.checkCancellation()
            items.append(
                LibraryItemSnapshot(
                    id: item.id,
                    title: item.title,
                    author: item.author,
                    genre: item.genre,
                    relation: item.relation,
                    keywordA: item.keywordA,
                    keywordB: item.keywordB,
                    memo: item.memo,
                    rating: item.rating,
                    bookType: item.bookType,
                    pages: item.pages,
                    isUnread: item.isUnread,
                    addedDate: item.addedDate,
                    lastReadDate: item.lastReadDate
                )
            )
            if index.isMultiple(of: 256) { await Task.yield() }
        }

        let shelfModels = try modelContext.fetch(FetchDescriptor<Shelf>())
        var shelves: [LibraryShelfSnapshot] = []
        shelves.reserveCapacity(shelfModels.count)
        for shelf in shelfModels {
            try Task.checkCancellation()
            shelves.append(
                LibraryShelfSnapshot(
                    id: shelf.id,
                    conditions: shelf.type == 1
                        ? SmartConditionsCodec.decode(shelf.smartConditionsJson)
                        : nil,
                    itemIDs: shelf.type == 1 ? [] : Set((shelf.items ?? []).map(\.id))
                )
            )
        }
        return LibrarySnapshotPayload(items: items, shelves: shelves)
    }

    nonisolated func isExecutingOnMainThread() async -> Bool {
        await executionThreadIsMain()
    }

    private func executionThreadIsMain() -> Bool {
        Thread.isMainThread
    }
}

nonisolated enum LibrarySnapshotLoader {
    @concurrent
    nonisolated static func makeReader(modelContainer: ModelContainer) async -> LibrarySnapshotReader {
        await Task.yield()
        return LibrarySnapshotReader(modelContainer: modelContainer)
    }

    nonisolated static func read(modelContainer: ModelContainer) async throws -> LibrarySnapshotPayload {
        let reader = await makeReader(modelContainer: modelContainer)
        try Task.checkCancellation()
        return try await reader.read()
    }
}

nonisolated enum LibraryRefreshPolicy {
    static let maximumPatchedItems = 128

    static func requiresFullSnapshot(
        hasStructuralChange: Bool,
        updatedItemCount: Int,
        relevantChangeCount: Int
    ) -> Bool {
        hasStructuralChange
            || updatedItemCount != relevantChangeCount
            || updatedItemCount > maximumPatchedItems
    }
}

struct LibraryProjectionRequest: Sendable {
    let selection: SidebarSelection?
    let search: String
    let equivalenceJSON: String
    let unreadOnly: Bool
    let ratings: Set<Int>
    let types: Set<Int>
    let sortKey: ItemSortKey
    let ascending: Bool
}

struct LibraryProjectionResult: Sendable {
    let ids: [UUID]
    let listRows: [LibraryListRowSnapshot]
    let unreadCount: Int
    let shelfCounts: [UUID: Int]
}

/// No managed objects cross this boundary. Cancellation is checked during scans
/// and sorting, so obsolete search work cannot delay the next query indefinitely.
actor LibraryProjectionWorker {
    static let shared = LibraryProjectionWorker()
    private let logger = Logger(subsystem: "com.eureka.ShelfRow", category: "LibraryPerformance")

    private var cachedGeneration: UInt64?
    private var previousMinute: Int?
    private var cachedUnread = 0
    private var cachedCounts: [UUID: Int] = [:]
    private var sortedItems: [LibraryItemSnapshot] = []
    private var cachedSortKey: ItemSortKey?
    private var normalizedText: [UUID: [String]] = [:]

    func project(
        _ items: [LibraryItemSnapshot],
        shelves: [LibraryShelfSnapshot],
        request: LibraryProjectionRequest,
        generation: UInt64 = 0
    ) throws -> LibraryProjectionResult {
        let start = ContinuousClock.now
        let query = KeywordEquivalenceCodec.normalize(request.search)
        let terms = KeywordEquivalenceCodec.searchTerms(
            for: request.search, rules: KeywordEquivalenceCodec.decode(request.equivalenceJSON)
        ).mapValues { $0.map { KeywordEquivalenceCodec.normalize($0) } }
        let now = Date()
        let cutoffs = Dictionary(uniqueKeysWithValues: shelves.compactMap { shelf -> (UUID, Date)? in
            guard let date = shelf.conditions?.date else { return nil }
            return (shelf.id, Calendar.current.date(byAdding: .day, value: -date.days, to: now) ?? now)
        })
        let minute = Int(now.timeIntervalSince1970 / 60)
        let dataChanged = cachedGeneration != generation
        let statisticsChanged = dataChanged || previousMinute != minute
        if dataChanged {
            normalizedText.removeAll(keepingCapacity: true)
        }
        if dataChanged || cachedSortKey != request.sortKey {
            var sorted = items
            try sorted.sort { a, b in
                try Task.checkCancellation()
                return Self.compare(a, b, key: request.sortKey) == .orderedAscending
            }
            sortedItems = sorted
            cachedSortKey = request.sortKey
        }
        var counts = statisticsChanged ? [:] : cachedCounts
        var unread = statisticsChanged ? 0 : cachedUnread
        var visible: [LibraryListRowSnapshot] = []
        visible.reserveCapacity(items.count)
        let selectedShelf = shelves.first { request.selection == .shelf($0.id) }
        for item in sortedItems {
            try Task.checkCancellation()
            if statisticsChanged {
                if item.isUnread { unread += 1 }
                for shelf in shelves {
                    let matches = shelf.conditions.map {
                        SmartConditionsCodec.matches(item, conditions: $0, cutOff: cutoffs[shelf.id])
                    } ?? shelf.itemIDs.contains(item.id)
                    if matches { counts[shelf.id, default: 0] += 1 }
                }
            }
            let selectedShelfMatches = selectedShelf.map { shelf in
                shelf.conditions.map { SmartConditionsCodec.matches(item, conditions: $0, cutOff: cutoffs[shelf.id]) }
                    ?? shelf.itemIDs.contains(item.id)
            } ?? false
            if case .shelf = request.selection, !selectedShelfMatches { continue }
            if (request.selection == .unreadBooks || request.unreadOnly), !item.isUnread { continue }
            if !request.ratings.isEmpty, !request.ratings.contains(item.rating) { continue }
            if !request.types.isEmpty, !request.types.contains(item.bookType) { continue }
            if !query.isEmpty {
                let fields: [String]
                if let cached = normalizedText[item.id] {
                    fields = cached
                } else {
                    fields = [item.title, item.author, item.genre, item.relation,
                              item.keywordA, item.keywordB, item.memo].map { KeywordEquivalenceCodec.normalize($0) }
                    normalizedText[item.id] = fields
                }
                let textMatches = fields.contains { $0.contains(query) }
                let aliasMatches = !textMatches && terms.contains { field, alternatives in
                    let fieldIndex: Int
                    switch field {
                    case .author: fieldIndex = 1
                    case .genre: fieldIndex = 2
                    case .relation: fieldIndex = 3
                    case .keywordA: fieldIndex = 4
                    case .keywordB: fieldIndex = 5
                    case .memo: fieldIndex = 6
                    }
                    return alternatives.contains { fields[fieldIndex].contains($0) }
                }
                if !textMatches && !aliasMatches { continue }
            }
            visible.append(LibraryListRowSnapshot(item))
        }
        try Task.checkCancellation()
        cachedGeneration = generation
        previousMinute = minute
        cachedUnread = unread
        cachedCounts = counts
        if !request.ascending { visible.reverse() }
        logger.debug("Projected \(items.count) items in \(String(describing: start.duration(to: .now)), privacy: .public)")
        return LibraryProjectionResult(
            ids: visible.map(\.id),
            listRows: visible,
            unreadCount: unread,
            shelfCounts: counts
        )
    }

    nonisolated private static func compare(_ a: LibraryItemSnapshot, _ b: LibraryItemSnapshot,
                                            key: ItemSortKey) -> ComparisonResult {
        func ordered<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult {
            x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
        }
        let primary: ComparisonResult
        switch key {
        case .title: primary = a.title.localizedStandardCompare(b.title)
        case .author: primary = a.author.localizedStandardCompare(b.author)
        case .genre: primary = a.genre.localizedStandardCompare(b.genre)
        case .relation: primary = a.relation.localizedStandardCompare(b.relation)
        case .keywordA: primary = a.keywordA.localizedStandardCompare(b.keywordA)
        case .keywordB: primary = a.keywordB.localizedStandardCompare(b.keywordB)
        case .rating: primary = ordered(a.rating, b.rating)
        case .bookType: primary = ordered(a.bookType, b.bookType)
        case .unread: primary = ordered(a.isUnread ? 0 : 1, b.isUnread ? 0 : 1)
        case .addedDate: primary = ordered(a.addedDate, b.addedDate)
        case .lastReadDate: primary = ordered(a.lastReadDate ?? .distantPast, b.lastReadDate ?? .distantPast)
        case .pages: primary = ordered(a.pages, b.pages)
        }
        if primary != .orderedSame { return primary }
        let title = a.title.localizedStandardCompare(b.title)
        return title == .orderedSame ? ordered(a.id.uuidString, b.id.uuidString) : title
    }
}
