import Testing
@testable import ShelfRow

struct LibraryKeyboardNavigationTests {
    @Test func repeatedDownAtEndCanImmediatelyReverse() {
        var selected = 0
        for _ in 0..<200 {
            if let next = LibraryKeyboardNavigation.destination(from: selected, by: 1, count: 36) {
                selected = next
            }
        }
        #expect(selected == 35)
        #expect(LibraryKeyboardNavigation.destination(from: selected, by: -1, count: 36) == 34)
    }

    @Test func repeatedUpAtStartCanImmediatelyReverse() {
        #expect(LibraryKeyboardNavigation.destination(from: 0, by: -1, count: 36) == nil)
        #expect(LibraryKeyboardNavigation.destination(from: 0, by: 1, count: 36) == 1)
    }

    @Test func gridStepsClampAndMissingSelectionStartsAtFirstItem() {
        #expect(LibraryKeyboardNavigation.destination(from: 34, by: 5, count: 36) == 35)
        #expect(LibraryKeyboardNavigation.destination(from: 35, by: -5, count: 36) == 30)
        #expect(LibraryKeyboardNavigation.destination(from: nil, by: 5, count: 36) == 0)
        #expect(LibraryKeyboardNavigation.destination(from: 0, by: 1, count: 0) == nil)
    }
}
