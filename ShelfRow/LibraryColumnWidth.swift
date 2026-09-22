import Foundation

/// Stores widths in unscaled points so compact display can apply its normal
/// scale without changing the user's saved value.
nonisolated enum LibraryColumnWidth {
    typealias Widths = [ItemSortKey: Double]

    static let maximum = 1_200.0

    static func minimum(for key: ItemSortKey) -> Double {
        switch key {
        case .unread, .bookType: 28
        case .rating: 72
        case .pages: 44
        case .lastReadDate, .addedDate: 68
        default: 60
        }
    }

    static func clamped(_ width: Double, for key: ItemSortKey) -> Double {
        guard width.isFinite else { return minimum(for: key) }
        return min(max(width, minimum(for: key)), maximum)
    }

    static func decode(_ rawValue: String) -> Widths {
        guard let data = rawValue.data(using: .utf8),
              let stored = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return stored.reduce(into: Widths()) { result, entry in
            guard let key = ItemSortKey(rawValue: entry.key),
                  LibraryColumnOrder.canonical.contains(key) else { return }
            result[key] = clamped(entry.value, for: key)
        }
    }

    static func encode(_ widths: Widths) -> String {
        let stored = widths.reduce(into: [String: Double]()) { result, entry in
            result[entry.key.rawValue] = clamped(entry.value, for: entry.key)
        }
        guard let data = try? JSONEncoder().encode(stored),
              let result = String(data: data, encoding: .utf8) else { return "{}" }
        return result
    }

    static func decodeScoped(_ rawValue: String) -> [String: Widths] {
        guard let data = rawValue.data(using: .utf8),
              let stored = try? JSONDecoder().decode([String: [String: Double]].self, from: data) else { return [:] }
        return stored.mapValues { rawWidths in
            rawWidths.reduce(into: Widths()) { result, entry in
                guard let key = ItemSortKey(rawValue: entry.key),
                      LibraryColumnOrder.canonical.contains(key) else { return }
                result[key] = clamped(entry.value, for: key)
            }
        }
    }

    static func encodeScoped(_ widthsByScope: [String: Widths]) -> String {
        let stored = widthsByScope.mapValues { widths in
            widths.reduce(into: [String: Double]()) { result, entry in
                result[entry.key.rawValue] = clamped(entry.value, for: entry.key)
            }
        }
        guard let data = try? JSONEncoder().encode(stored),
              let result = String(data: data, encoding: .utf8) else { return "{}" }
        return result
    }
}
