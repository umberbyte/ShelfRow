//
//  CloudSeedProgress.swift
//  ShelfRow
//

import Foundation
import OSLog
import SQLite3
import SwiftData

/// How much of the library iCloud has taken so far.
struct CloudSeedProgress: Sendable, Equatable {
    let mirrored: Int
    let total: Int

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(mirrored) / Double(total))
    }

    var isComplete: Bool { total > 0 && mirrored >= total }
}

/// Counts the records CloudKit has acknowledged, by reading the bookkeeping
/// table SwiftData keeps inside the store file.
///
/// **This reads a private schema.** `NSPersistentCloudKitContainer.Event`
/// publishes start and end times and nothing else, so the number of records
/// still to go is written down in exactly one place: the mirroring delegate's
/// own metadata table, alongside the app's data in the same SQLite file.
/// Nothing here is API, and an OS update may rename or restructure it — so the
/// table is looked up by pattern rather than by name, every failure returns nil,
/// and the settings pane falls back to showing activity without a percentage.
enum CloudSeedProgressReader {
    private static let logger = Logger(subsystem: ThumbnailCache.appIdentifier, category: "CloudSeedProgress")

    /// Set once a read fails, so a broken schema is not re-probed every tick.
    private nonisolated(unsafe) static var isUnavailable = false

    @MainActor
    static func read(container: ModelContainer) -> CloudSeedProgress? {
        guard !isUnavailable else { return nil }
        guard let storeURL = container.configurations.first(where: { $0.name == "Library" })?.url,
              let mirrored = mirroredRecordCount(storeURL: storeURL) else {
            return nil
        }

        let context = container.mainContext
        var total = 0
        total += (try? context.fetchCount(FetchDescriptor<Item>())) ?? 0
        total += (try? context.fetchCount(FetchDescriptor<Shelf>())) ?? 0
        total += (try? context.fetchCount(FetchDescriptor<Volume>())) ?? 0
        total += (try? context.fetchCount(FetchDescriptor<CoverExtractionRecord>())) ?? 0

        guard total > 0 else { return nil }
        return CloudSeedProgress(mirrored: mirrored, total: total)
    }

    /// Opens a second, read-only connection to the store Core Data is writing.
    /// SQLite allows this; the shared-memory file it needs is already there
    /// because this process has the store open.
    private static func mirroredRecordCount(storeURL: URL) -> Int? {
        var database: OpaquePointer?
        let uri = storeURL.absoluteString + "?mode=ro"
        guard sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            markUnavailable("could not open the store read-only")
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }

        guard let table = mirroringMetadataTable(in: database) else {
            markUnavailable("no CloudKit metadata table in this store")
            return nil
        }
        // A row exists for every object from the moment it is queued, so the
        // rows themselves say nothing about progress — the flag on them does.
        guard let pendingColumn = column(matching: "%NEEDSUPLOAD%", of: table, in: database) else {
            markUnavailable("no upload flag on \(table)")
            return nil
        }
        // Both names come from sqlite_master / PRAGMA and are matched against
        // fixed patterns, so neither can carry anything but an identifier.
        guard let uploaded = singleValue(
            "SELECT COUNT(*) FROM \(table) WHERE \(pendingColumn) = 0", in: database
        ) else {
            markUnavailable("could not count uploaded rows in \(table)")
            return nil
        }

        logOnce(table: table, column: pendingColumn, uploaded: uploaded, in: database)
        return uploaded
    }

    private static func column(matching pattern: String, of table: String, in database: OpaquePointer?) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let wanted = pattern.replacingOccurrences(of: "%", with: "")
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 1) else { continue }
            let name = String(cString: raw)
            if name.uppercased().contains(wanted) { return name }
        }
        return nil
    }

    private static func mirroringMetadataTable(in database: OpaquePointer?) -> String? {
        let query = """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND upper(name) LIKE '%CKRECORDMETADATA%'
            ORDER BY length(name) LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let name = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: name)
    }

    private static func singleValue(_ query: String, in database: OpaquePointer?) -> Int? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private nonisolated(unsafe) static var didLogSchema = false

    /// One line, once per launch, so a schema that has drifted under an OS
    /// update can be recognised from the log rather than guessed at.
    private static func logOnce(table: String, column: String, uploaded: Int, in database: OpaquePointer?) {
        guard !didLogSchema else { return }
        didLogSchema = true
        let rows = singleValue("SELECT COUNT(*) FROM \(table)", in: database) ?? -1
        logger.info("\(table, privacy: .public): \(uploaded, privacy: .public) of \(rows, privacy: .public) rows have \(column, privacy: .public) = 0")
    }

    private static func markUnavailable(_ reason: String) {
        isUnavailable = true
        logger.info("Seed progress is unavailable (\(reason, privacy: .public)); falling back to activity only")
    }
}
