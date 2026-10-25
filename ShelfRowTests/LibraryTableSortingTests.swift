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

/// Whether to let the input settle before rebuilding the list.
struct LibraryRefreshSettlingTests {
    @Test func typingWaits() {
        // Each keystroke would otherwise project the whole library.
        #expect(LibraryRefreshDecision.settlesFirst(searchText: "ab", lastProjectedSearchText: "a"))
        #expect(LibraryRefreshDecision.settlesFirst(searchText: "", lastProjectedSearchText: "a"))
    }

    @Test func changingShelfDoesNot() {
        // One event, and the wait is felt immediately.
        #expect(!LibraryRefreshDecision.settlesFirst(searchText: "a", lastProjectedSearchText: "a"))
        #expect(!LibraryRefreshDecision.settlesFirst(searchText: "", lastProjectedSearchText: ""))
    }
}

/// Whether a save's structural change can be folded into the list.
struct LibraryFoldDecisionTests {
    @Test func arrivalsAreFolded() {
        #expect(LibraryRefreshDecision.canFoldStructuralChange(
            hasSnapshot: true, insertedItemCount: 1, removedItemCount: 0
        ))
    }

    @Test func aDeletionIsNotFolded() {
        // A deleted model cannot be asked which book it was — reading any of its
        // properties traps — so there is no way to know what to take out of the
        // list. Reading the library again is what deletion costs. Getting this
        // wrong crashed the app on right-click, delete.
        #expect(!LibraryRefreshDecision.canFoldStructuralChange(
            hasSnapshot: true, insertedItemCount: 1, removedItemCount: 1
        ))
        #expect(!LibraryRefreshDecision.canFoldStructuralChange(
            hasSnapshot: true, insertedItemCount: 0, removedItemCount: 1
        ))
    }

    @Test func nothingIsFoldedIntoAListThatDoesNotExistYet() {
        #expect(!LibraryRefreshDecision.canFoldStructuralChange(
            hasSnapshot: false, insertedItemCount: 3, removedItemCount: 0
        ))
    }

    @Test func aChangeWithNoArrivalsHasNothingToFold() {
        #expect(!LibraryRefreshDecision.canFoldStructuralChange(
            hasSnapshot: true, insertedItemCount: 0, removedItemCount: 0
        ))
    }
}

/// What a press of delete is about to do.
struct PendingDeletionTests {
    @Test func deletingFromTheLibrarySaysSoAndThatFilesRemain() {
        let deletion = ContentView.PendingDeletion(itemIDs: [UUID(), UUID()], shelfID: nil)

        #expect(deletion.prompt.contains("2件"))
        #expect(deletion.prompt.contains("ライブラリ"))
        #expect(deletion.confirmTitle == "削除")
        // The distinction a person needs before pressing it: the books go, the
        // files do not.
        #expect(deletion.explanation.contains("ファイル自体は残ります"))
    }

    @Test func takingBooksOffAShelfIsNotDeletingThem() {
        let deletion = ContentView.PendingDeletion(itemIDs: [UUID()], shelfID: UUID())

        #expect(deletion.prompt.contains("シェルフから外しますか"))
        #expect(deletion.confirmTitle == "外す")
        #expect(deletion.explanation.contains("ライブラリには残ります"))
    }
}

/// What a right-click acts on, and which way a mixed selection is marked.
struct LibraryContextTargetTests {
    @Test func clickingInsideASelectionActsOnAllOfIt() {
        let a = UUID(), b = UUID(), c = UUID()
        let targets = Set(LibraryContextTarget.ids(clicked: b, selection: [a, b, c]))

        #expect(targets == [a, b, c])
    }

    @Test func clickingOutsideASelectionActsOnWhatWasClicked() {
        let a = UUID(), b = UUID(), outsider = UUID()
        #expect(LibraryContextTarget.ids(clicked: outsider, selection: [a, b]) == [outsider])
    }

    @Test func oneBookSelectedIsJustThatBook() {
        let a = UUID()
        #expect(LibraryContextTarget.ids(clicked: a, selection: [a]) == [a])
        #expect(LibraryContextTarget.ids(clicked: a, selection: []) == [a])
    }

    @Test func unreadFollowsTheMajorityRatherThanTogglingEachBook() {
        // Toggling one by one would leave a mixed selection mixed the other way
        // round, which is not what the menu means.
        #expect(LibraryUnreadToggle.marksUnread(unreadCount: 1, total: 5))
        #expect(!LibraryUnreadToggle.marksUnread(unreadCount: 4, total: 5))
        // A tie marks unread: that is the state someone is reaching for.
        #expect(LibraryUnreadToggle.marksUnread(unreadCount: 2, total: 4))
    }
}

/// One read of the library at a time.
struct LibraryReadQueueTests {
    @Test func theFirstReadStarts() {
        var queue = LibraryReadQueue()
        // Bound first: #expect cannot call a mutating member on its operand.
        let started = queue.beginOrDefer()

        #expect(started)
        #expect(queue.isReading)
    }

    @Test func aSecondRequestWaitsRatherThanReplacingTheFirst() {
        // The bug this pins: under a running sync a request arrives every second
        // or two, a read takes about four, and starting the new one in place of
        // the old meant none ever finished — books added by a drop stayed
        // invisible until the app was restarted.
        var queue = LibraryReadQueue()
        let first = queue.beginOrDefer()
        let second = queue.beginOrDefer()
        let third = queue.beginOrDefer()

        #expect(first)
        #expect(!second)
        #expect(!third)
        #expect(queue.isReading)
        #expect(queue.wantsAnother)
    }

    @Test func whatWaitedIsRunOnceWhenTheReadIsDone() {
        var queue = LibraryReadQueue()
        _ = queue.beginOrDefer()
        _ = queue.beginOrDefer()
        _ = queue.beginOrDefer()

        // Three requests while reading, one read afterwards: by then it covers
        // everything that arrived.
        let another = queue.finish()

        #expect(another)
        #expect(!queue.isReading)
        #expect(!queue.wantsAnother)
    }

    @Test func aQuietReadAsksForNothingFurther() {
        var queue = LibraryReadQueue()
        _ = queue.beginOrDefer()
        let another = queue.finish()

        #expect(!another)
    }
}

/// Shelf membership, as the list filters by it.
struct LibraryShelfSnapshotTests {
    @Test func booksDroppedOnAShelfAreOnItAtOnce() {
        // The membership the list filters by is a copy taken when the library
        // was last read. Left unamended, a drop onto a shelf arrived in the
        // library and not on the shelf it was dropped on.
        let shelf = LibraryShelfSnapshot(id: UUID(), conditions: nil, itemIDs: [])
        let first = UUID()
        let second = UUID()

        #expect(shelf.adding([first, second]).itemIDs == [first, second])
        #expect(shelf.adding([first]).adding([first]).itemIDs == [first])
    }

    @Test func booksTakenOffAShelfLeaveIt() {
        let kept = UUID()
        let removed = UUID()
        let shelf = LibraryShelfSnapshot(id: UUID(), conditions: nil, itemIDs: [kept, removed])

        #expect(shelf.removing([removed]).itemIDs == [kept])
    }

    @Test func aSmartShelfKeepsNoMembershipOfItsOwn() {
        // It answers by condition; nothing is put on one or taken off by hand.
        let smart = LibraryShelfSnapshot(
            id: UUID(),
            conditions: SmartConditions(),
            itemIDs: []
        )

        #expect(smart.adding([UUID()]) == smart)
        #expect(smart.removing([UUID()]) == smart)
    }
}
