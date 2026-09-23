import Foundation
import Testing
@testable import ShelfRow

struct LibraryColumnWidthTests {
    @Test func widthsRoundTripAndUnknownColumnsAreIgnored() {
        let decoded = LibraryColumnWidth.decode("{\"title\":240,\"author\":130,\"unknown\":99}")

        #expect(decoded[.title] == 240)
        #expect(decoded[.author] == 130)
        #expect(decoded.count == 2)
        #expect(LibraryColumnWidth.decode(LibraryColumnWidth.encode(decoded)) == decoded)
    }

    @Test func widthsAreClampedToUsableBounds() {
        let decoded = LibraryColumnWidth.decode("{\"title\":12,\"rating\":5000}")

        #expect(decoded[.title] == LibraryColumnWidth.minimum(for: .title))
        #expect(decoded[.rating] == LibraryColumnWidth.maximum)
    }

    @Test func visualDragDirectionChangesWidthInTheSameDirection() {
        let rightDrag = LibraryColumnWidth.logicalDragDelta(translation: 30, displayScale: 1)
        let leftDrag = LibraryColumnWidth.logicalDragDelta(translation: -30, displayScale: 1)

        #expect(LibraryColumnWidth.resized(200, by: rightDrag, for: .title) == 230)
        #expect(LibraryColumnWidth.resized(200, by: leftDrag, for: .title) == 170)
    }

    @Test func compactDragPreservesDirectionAndConvertsToLogicalPoints() {
        let scale = Double(DisplayMetrics.elementScale)

        #expect(LibraryColumnWidth.logicalDragDelta(translation: 30, displayScale: scale) == 40)
        #expect(LibraryColumnWidth.logicalDragDelta(translation: -30, displayScale: scale) == -40)
    }

    @Test func slowFixedCoordinateDragProducesMonotonicWidths() {
        let translations = stride(from: CGFloat(0), through: 20, by: 0.25)
        let widths = translations.map { translation in
            let delta = LibraryColumnWidth.logicalDragDelta(
                translation: translation,
                displayScale: Double(DisplayMetrics.elementScale)
            )
            return LibraryColumnWidth.resized(200, by: delta, for: .title)
        }

        #expect(zip(widths, widths.dropFirst()).allSatisfy { current, next in
            next >= current
        })
    }

    @Test func compactValueColumnsUseFixedWidthsThatFitTheirContents() {
        let fixed: [ItemSortKey] = [.rating, .addedDate, .lastReadDate, .bookType, .unread]

        #expect(fixed.allSatisfy { !LibraryColumnWidth.isResizable($0) })
        #expect(fixed.allSatisfy {
            guard let width = LibraryColumnWidth.defaultWidth(for: $0) else { return false }
            return width >= LibraryColumnWidth.minimum(for: $0)
        })
        #expect(LibraryColumnWidth.isResizable(.title))
        #expect(LibraryColumnWidth.isResizable(.author))
    }

    @Test func perCollectionWidthsRoundTripIndependently() {
        let shelfID = UUID()
        let widths: [String: LibraryColumnWidth.Widths] = [
            LibraryColumnOrder.scopeKey(for: .allBooks): [.title: 260],
            LibraryColumnOrder.scopeKey(for: .shelf(shelfID)): [.title: 180, .author: 150]
        ]

        let decoded = LibraryColumnWidth.decodeScoped(LibraryColumnWidth.encodeScoped(widths))

        #expect(decoded[LibraryColumnOrder.scopeKey(for: .allBooks)]?[.title] == 260)
        #expect(decoded[LibraryColumnOrder.scopeKey(for: .shelf(shelfID))]?[.title] == 180)
        #expect(decoded[LibraryColumnOrder.scopeKey(for: .shelf(shelfID))]?[.author] == 150)
    }

    @Test func headerAndRowsUseTheSameEffectiveInsetAtEveryDisplayScale() {
        for metrics in [DisplayMetrics.regular, DisplayMetrics.compact] {
            let rowInset = LibraryListLayout.rowBackgroundInset(metrics)
                + LibraryListLayout.rowInnerInset(metrics)

            #expect(rowInset == LibraryListLayout.contentInset(metrics))
        }
    }
}
