//
//  LibraryTableSorting.swift
//  ShelfRow
//

import AppKit

/// A column and a direction, as the list understands them.
struct LibraryTableSortSelection: Equatable, Sendable {
    let key: ItemSortKey
    let ascending: Bool
}

/// Translates between the list's idea of sorting and AppKit's.
///
/// `NSTableView` sorts by handing columns an `NSSortDescriptor` and telling the
/// delegate when the person has changed it. Nothing of ours sorts by key path,
/// so the descriptor carries only the column's name; the comparison stays where
/// it already is, in the projection.
enum LibraryTableSortDescriptor {
    static func make(key: ItemSortKey, ascending: Bool) -> NSSortDescriptor {
        NSSortDescriptor(key: key.rawValue, ascending: ascending)
    }

    /// The column and direction a set of descriptors asks for.
    ///
    /// Only the first is read — the list sorts by one column — and a descriptor
    /// naming something that is not a column is ignored rather than guessed at,
    /// which is what an empty table or a stale saved layout will hand over.
    static func selection(from descriptors: [NSSortDescriptor]) -> LibraryTableSortSelection? {
        guard let descriptor = descriptors.first,
              let name = descriptor.key,
              let key = ItemSortKey(rawValue: name) else {
            return nil
        }
        return LibraryTableSortSelection(key: key, ascending: descriptor.ascending)
    }
}

/// Which row a book is, for the one caller that has to scroll to it.
///
/// Separated from the scrolling so the decision can be tried without a window:
/// a book the list does not have is not a row to leave the person staring at,
/// it is a target to keep waiting for.
enum LibraryTableScrollTarget {
    static func row(for itemID: UUID?, in rows: [LibraryListRowSnapshot]) -> Int? {
        guard let itemID else { return nil }
        return rows.firstIndex { $0.id == itemID }
    }
}

/// What a right-click acts on.
///
/// Clicking inside a selection means the selection; clicking outside it means
/// the one row clicked. It is how every list on the system behaves, and getting
/// it wrong means a menu raised over twenty selected books quietly acting on
/// one of them.
enum LibraryContextTarget {
    static func ids(clicked id: UUID, selection: Set<UUID>) -> [UUID] {
        guard selection.count > 1, selection.contains(id) else { return [id] }
        return Array(selection)
    }
}

/// Which way "未読チェック" moves a selection.
///
/// Toggling each book separately would leave a mixed selection mixed, only the
/// other way round, which is not what the menu means. The majority decides, and
/// ties mark unread — the state someone is usually reaching for.
enum LibraryUnreadToggle {
    static func marksUnread(unreadCount: Int, total: Int) -> Bool {
        unreadCount * 2 <= total
    }
}

/// Keeps one read of the library in flight at a time.
///
/// Reading a library of twenty thousand books takes seconds, and a running
/// iCloud import asks for a fresh one every second or two. Starting the newer
/// request in place of the running one — the obvious reading of "the data
/// changed again" — means no read ever finishes, and anything waiting on one
/// never appears. The later request waits instead, and is run once when the
/// current read is done, by which time it covers everything that arrived.
struct LibraryReadQueue {
    private(set) var isReading = false
    private(set) var wantsAnother = false

    /// Answers whether to start now. A no means it has been remembered.
    mutating func beginOrDefer() -> Bool {
        guard !isReading else {
            deferAnother()
            return false
        }
        isReading = true
        return true
    }

    /// Remembers that the library should be read again.
    mutating func deferAnother() {
        wantsAnother = true
    }

    /// Answers whether another read was asked for while this one ran.
    mutating func finish() -> Bool {
        isReading = false
        guard wantsAnother else { return false }
        wantsAnother = false
        return true
    }
}
