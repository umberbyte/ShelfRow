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
