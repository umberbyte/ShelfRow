import AppKit
import Testing
@testable import ShelfRow

struct LibraryTableSortingTests {
    @Test @MainActor
    func nativeSortDescriptorRoundTripsEveryColumnAndDirection() throws {
        for key in ItemSortKey.allCases {
            for ascending in [true, false] {
                let descriptor = LibraryTableSortDescriptor.make(
                    key: key,
                    ascending: ascending
                )
                let selection = try #require(
                    LibraryTableSortDescriptor.selection(from: [descriptor])
                )
                #expect(selection == LibraryTableSortSelection(
                    key: key,
                    ascending: ascending
                ))
            }
        }
    }

    @Test @MainActor
    func unknownOrMissingSortDescriptorIsIgnored() {
        let unknown = NSSortDescriptor(key: "not-a-column", ascending: true)
        #expect(LibraryTableSortDescriptor.selection(from: []) == nil)
        #expect(LibraryTableSortDescriptor.selection(from: [unknown]) == nil)
    }
}
