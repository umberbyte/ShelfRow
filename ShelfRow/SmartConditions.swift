//
//  SmartConditions.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import Foundation
import SwiftUI

/// Shared visual constants for the six classic Stackroom book types
/// (厚い本 / 薄い本 / 本の一部 / 画像セット / テキスト / ムービー).
enum BookTypeInfo {
    static let count = 6

    static func color(for index: Int) -> Color {
        switch index {
        case 0: return .yellow
        case 1: return .blue
        case 2: return .green
        case 3: return .pink
        case 4: return .gray
        case 5: return .purple
        default: return .secondary
        }
    }

    static func systemImage(for index: Int) -> String {
        switch index {
        case 4: return "doc.text.fill"
        case 5: return "film.fill"
        default: return "book.closed.fill"
        }
    }

    /// Classic Stackroom folder icon colors used in the sidebar / smart shelf dialog.
    static func folderColor(forIcon icon: Int) -> Color {
        switch icon % 7 {
        case 1: return .yellow
        case 2: return .blue
        case 3: return .green
        case 4: return .pink
        case 5: return .purple
        case 6: return .orange
        default: return Color(NSColor.systemBrown)
        }
    }
}

/// Decoded smart shelf filter conditions.
/// Serialized into `Shelf.smartConditionsJson` using the same top-level keys
/// as the legacy Stackroom XML ("Keyword Condition", "Date Condition", ...)
/// so that imported legacy definitions keep working.
struct SmartConditions: Equatable {
    struct Keyword: Equatable {
        var field: String = "Title" // Title / Author / Genre / Relation / Keyword A / Keyword B / Neta
        var text: String = ""
        var mode: Int = 0           // 0 = contains, 1 = not contains, 2 = equals
    }
    struct DateCondition: Equatable {
        var field: Int = 0          // 0 = 登録した日, 1 = 最後に読んだ日
        var days: Int = 30
        var mode: Int = 0           // 0 = 日以内, 1 = 日以上前
    }

    var keyword: Keyword? = nil
    var date: DateCondition? = nil
    var types: Set<Int>? = nil      // selected bookType indices, nil = ALL
    var rates: Set<Int>? = nil      // selected ratings 1...5, nil = ALL
    var unreadOnly: Bool = false
}

enum SmartConditionsCodec {

    /// Decodes a JSON conditions string. Tolerates both the legacy imported
    /// dictionaries and the ones produced by `encode`.
    static func decode(_ json: String?) -> SmartConditions {
        var result = SmartConditions()
        guard let json,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return result
        }

        if let kw = dict["Keyword Condition"] as? [String: Any] {
            var keyword = SmartConditions.Keyword()
            keyword.field = kw["Condition"] as? String ?? "Title"
            keyword.text = kw["Key"] as? String ?? ""
            keyword.mode = kw["Option"] as? Int ?? 0
            if !keyword.text.isEmpty {
                result.keyword = keyword
            }
        }

        if let dc = dict["Date Condition"] as? [String: Any] {
            var date = SmartConditions.DateCondition()
            // Legacy stores days in "Key"; field/mode are additions.
            if let days = dc["Key"] as? Int {
                date.days = days
            } else if let daysString = dc["Key"] as? String, let days = Int(daysString) {
                date.days = days
            }
            date.field = dc["Condition"] as? Int ?? 0
            date.mode = dc["Option"] as? Int ?? 0
            result.date = date
        }

        if let tc = dict["Type Condition"] as? [String: Any], let values = tc["Key"] as? [Int], !values.isEmpty {
            result.types = Set(values)
        }
        if let rc = dict["Rate Condition"] as? [String: Any], let values = rc["Key"] as? [Int], !values.isEmpty {
            result.rates = Set(values)
        }
        if let uc = dict["Unseen Condition"] as? [String: Any] {
            result.unreadOnly = (uc["Key"] as? Bool) ?? ((uc["Key"] as? Int).map { $0 != 0 } ?? false)
        }

        return result
    }

    /// Encodes conditions into a JSON string, omitting disabled categories.
    static func encode(_ conditions: SmartConditions) -> String? {
        var dict: [String: Any] = [:]

        if let keyword = conditions.keyword, !keyword.text.isEmpty {
            dict["Keyword Condition"] = [
                "Condition": keyword.field,
                "Key": keyword.text,
                "Option": keyword.mode
            ]
        }
        if let date = conditions.date {
            dict["Date Condition"] = [
                "Condition": date.field,
                "Key": date.days,
                "Option": date.mode
            ]
        }
        if let types = conditions.types, !types.isEmpty {
            dict["Type Condition"] = ["Key": Array(types).sorted()]
        }
        if let rates = conditions.rates, !rates.isEmpty {
            dict["Rate Condition"] = ["Key": Array(rates).sorted()]
        }
        if conditions.unreadOnly {
            dict["Unseen Condition"] = ["Key": true]
        }

        guard !dict.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: dict) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Extracts the searchable string value of an Item for a keyword field key.
    private static func fieldValue(of item: Item, forField field: String) -> String {
        switch field.lowercased() {
        case "title": return item.title
        case "author": return item.author
        case "genre": return item.genre
        case "relation": return item.relation
        case "keyword a", "keyworda": return item.keywordA
        case "keyword b", "keywordb": return item.keywordB
        case "neta", "memo": return item.memo
        default:
            // Unknown legacy field: search across all text fields.
            return [item.title, item.author, item.genre, item.relation,
                    item.keywordA, item.keywordB, item.memo].joined(separator: "\n")
        }
    }

    /// Evaluates whether an Item matches all enabled conditions (AND semantics).
    static func matches(_ item: Item, conditions: SmartConditions, now: Date = Date()) -> Bool {
        if let keyword = conditions.keyword, !keyword.text.isEmpty {
            let value = fieldValue(of: item, forField: keyword.field).lowercased()
            let key = keyword.text.lowercased()
            switch keyword.mode {
            case 1:  if value.contains(key) { return false }        // でない項目
            case 2:  if value != key { return false }               // と一致する項目
            default: if !value.contains(key) { return false }       // の項目 (含む)
            }
        }

        if let date = conditions.date {
            let target: Date? = date.field == 1 ? item.lastReadDate : item.addedDate
            let cutOff = Calendar.current.date(byAdding: .day, value: -date.days, to: now) ?? now
            switch date.mode {
            case 1: // 日以上前の項目
                guard let target, target < cutOff else { return false }
            default: // 日以内の項目
                guard let target, target >= cutOff else { return false }
            }
        }

        if let types = conditions.types, !types.isEmpty, !types.contains(item.bookType) {
            return false
        }
        if let rates = conditions.rates, !rates.isEmpty, !rates.contains(item.rating) {
            return false
        }
        if conditions.unreadOnly && !item.isUnread {
            return false
        }

        return true
    }
}
