import AppKit
import Foundation
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

/// Finding the row to scroll to after a book is registered.
struct LibraryTableScrollTargetTests {
    private func row(_ id: UUID) -> LibraryListRowSnapshot {
        LibraryListRowSnapshot(
            LibraryItemSnapshot(
                id: id,
                title: "本",
                author: "",
                genre: "",
                relation: "",
                keywordA: "",
                keywordB: "",
                memo: "",
                rating: 0,
                bookType: 0,
                pages: 0,
                isUnread: false,
                addedDate: Date(),
                lastReadDate: nil
            )
        )
    }

    @Test func aBookTheListHasIsTheRowItIsAt() {
        let first = UUID()
        let second = UUID()
        #expect(LibraryTableScrollTarget.row(for: second, in: [row(first), row(second)]) == 1)
    }

    @Test func aBookTheListDoesNotHaveYetIsNoRowAtAll() {
        // It stays waiting rather than scrolling somewhere arbitrary: the
        // projection is rebuilt after registration, so the row arrives late.
        #expect(LibraryTableScrollTarget.row(for: UUID(), in: [row(UUID())]) == nil)
        #expect(LibraryTableScrollTarget.row(for: nil, in: [row(UUID())]) == nil)
        #expect(LibraryTableScrollTarget.row(for: UUID(), in: []) == nil)
    }
}

/// When rebuilding the list has to read the library again.
struct LibraryRefreshDecisionTests {
    @Test func theFirstRebuildAlwaysReads() {
        // Nothing to project from yet, whatever asked for it.
        for reason in [LibraryRefreshReason.request, .library] {
            #expect(LibraryRefreshDecision.needsSnapshot(
                reason: reason,
                snapshotGeneration: 0,
                libraryGeneration: 5,
                requiresFullSnapshot: false
            ))
        }
    }

    @Test func switchingShelvesNeverWaitsOnTheLibrary() {
        // The point of the distinction: during an iCloud import the library is
        // changing constantly, and a shelf change that insisted on a fresh read
        // would never finish one.
        #expect(!LibraryRefreshDecision.needsSnapshot(
            reason: .request,
            snapshotGeneration: 3,
            libraryGeneration: 99,
            requiresFullSnapshot: true
        ))
    }

    @Test func aChangedLibraryIsReadAgain() {
        #expect(LibraryRefreshDecision.needsSnapshot(
            reason: .library,
            snapshotGeneration: 3,
            libraryGeneration: 4,
            requiresFullSnapshot: false
        ))
        #expect(LibraryRefreshDecision.needsSnapshot(
            reason: .library,
            snapshotGeneration: 3,
            libraryGeneration: 3,
            requiresFullSnapshot: true
        ))
    }

    @Test func aLibraryAlreadyInHandIsNotReadTwice() {
        #expect(!LibraryRefreshDecision.needsSnapshot(
            reason: .library,
            snapshotGeneration: 7,
            libraryGeneration: 7,
            requiresFullSnapshot: false
        ))
    }
}
