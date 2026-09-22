import Foundation

/// Persists a complete order, including currently hidden columns, so showing a
/// column again puts it back where the user last placed it.
nonisolated enum LibraryColumnOrder {
    static let canonical: [ItemSortKey] = [
        .unread, .bookType, .title, .rating, .author, .genre,
        .relation, .keywordA, .keywordB, .lastReadDate, .addedDate
    ]

    static func decode(_ rawValue: String) -> [ItemSortKey] {
        var seen: Set<ItemSortKey> = []
        var result = rawValue
            .split(separator: ",")
            .compactMap { ItemSortKey(rawValue: String($0)) }
            .filter { seen.insert($0).inserted && canonical.contains($0) }
        result.append(contentsOf: canonical.filter { !seen.contains($0) })
        return result
    }

    static func encode(_ order: [ItemSortKey]) -> String {
        order.map(\.rawValue).joined(separator: ",")
    }

    /// Crossing a target places the dragged column on the far side of that
    /// target, which makes repeated `dropEntered` events feel like native table
    /// column movement in both directions.
    static func moving(
        _ source: ItemSortKey,
        across target: ItemSortKey,
        in order: [ItemSortKey]
    ) -> [ItemSortKey] {
        guard source != target,
              let sourceIndex = order.firstIndex(of: source),
              let targetIndex = order.firstIndex(of: target) else { return order }
        var result = order
        let moved = result.remove(at: sourceIndex)
        let destination = sourceIndex < targetIndex ? targetIndex : targetIndex
        result.insert(moved, at: destination)
        return result
    }

    static func scopeKey(for selection: SidebarSelection?) -> String {
        switch selection {
        case .allBooks, .none: "library.all"
        case .unreadBooks: "library.unread"
        case .shelf(let id): "shelf.\(id.uuidString)"
        }
    }

    static func decodeScoped(_ rawValue: String) -> [String: [ItemSortKey]] {
        guard let data = rawValue.data(using: .utf8),
              let stored = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return stored.mapValues { decode($0.joined(separator: ",")) }
    }

    static func encodeScoped(_ orders: [String: [ItemSortKey]]) -> String {
        let stored = orders.mapValues { $0.map(\.rawValue) }
        guard let data = try? JSONEncoder().encode(stored),
              let result = String(data: data, encoding: .utf8) else { return "{}" }
        return result
    }
}
