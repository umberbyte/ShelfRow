import Foundation
import Testing
@testable import ShelfRow

struct LibraryColumnOrderTests {
    @Test func decodingRepairsMissingDuplicateAndUnknownColumns() {
        let decoded = LibraryColumnOrder.decode("author,title,author,unknown")

        #expect(decoded.prefix(2) == [.author, .title])
        #expect(decoded.count == LibraryColumnOrder.canonical.count)
        #expect(Set(decoded) == Set(LibraryColumnOrder.canonical))
    }

    @Test func draggingAColumnMovesItAcrossTheTarget() {
        let original: [ItemSortKey] = [.unread, .bookType, .title, .rating]

        #expect(LibraryColumnOrder.moving(.unread, across: .title, in: original)
            == [.bookType, .title, .unread, .rating])
        #expect(LibraryColumnOrder.moving(.rating, across: .bookType, in: original)
            == [.unread, .rating, .bookType, .title])
    }

    @Test func perCollectionOrdersRoundTripIndependently() {
        let shelfID = UUID()
        let orders: [String: [ItemSortKey]] = [
            LibraryColumnOrder.scopeKey(for: .allBooks): [.title, .author],
            LibraryColumnOrder.scopeKey(for: .shelf(shelfID)): [.author, .title]
        ]

        let encoded = LibraryColumnOrder.encodeScoped(orders)
        let decoded = LibraryColumnOrder.decodeScoped(encoded)

        #expect(decoded[LibraryColumnOrder.scopeKey(for: .allBooks)]?.prefix(2) == [.title, .author])
        #expect(decoded[LibraryColumnOrder.scopeKey(for: .shelf(shelfID))]?.prefix(2) == [.author, .title])
        #expect(decoded[LibraryColumnOrder.scopeKey(for: .unreadBooks)] == nil)
    }

    @Test func nativeTableReorderPreservesHiddenColumnSlots() {
        let complete: [ItemSortKey] = [.unread, .bookType, .title, .rating, .author, .genre]
        let reorderedVisible: [ItemSortKey] = [.title, .unread, .author]

        let merged = LibraryColumnOrder.mergingVisibleOrder(
            reorderedVisible,
            into: complete
        )

        #expect(merged == [.title, .bookType, .unread, .rating, .author, .genre])
    }
}
